#!/bin/bash
# Kolonie AI — Deployment Script
# Called by GitHub Actions after image build

set -euo pipefail

# Overridable so the script can be rehearsed against a scratch directory with a
# stub `docker` on PATH. The deploy workflow does not forward it, so on the host
# this is always /opt/kolonie — the override exists to make the most dangerous
# script in this repository testable at all, not to make its target configurable.
DEPLOY_DIR="${DEPLOY_DIR:-/opt/kolonie}"
BACKUP_DIR="${DEPLOY_DIR}/backups"
STATE_DIR="${DEPLOY_DIR}/state"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SERVICE=${1:-all}

# Serialize deploys to prevent concurrent migrations and race conditions (#29)
mkdir -p "$STATE_DIR"
exec 9>>"${STATE_DIR}/deploy.lock"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for another deploy to finish..."
    flock -w 600 9 || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Timeout waiting for deploy lock"; exit 1; }
fi

# The mutable pointers: what to probe, what to pull. Never what to run — pin()
# turns each of these into a digest before anything is started.
API_REPO="ghcr.io/kolonie-ai/kolonie-api"
RUNNER_REPO="ghcr.io/kolonie-ai/kolonie-verifier-runner"
# The fourth image (kolonie-platform#55). It judges what citizens write about a
# task before any other agent reads it, and like the verifier runner it has no
# Traefik route: it reads Postgres and talks outward to OpenRouter.
MODERATION_REPO="ghcr.io/kolonie-ai/kolonie-moderation-runner"
# The fifth (kolonie-platform#105). It reads the support tickets citizens file,
# matches them against work the Colony already has, and files what is new — so
# like the other two runners it has no Traefik route: it reads Postgres and talks
# outward to OpenRouter and GitHub.
TRIAGE_REPO="ghcr.io/kolonie-ai/kolonie-support-triage-runner"
# The sixth (kolonie-platform#241). It sweeps the badge criteria every six hours
# and awards what has newly become true. The only runner that speaks to nothing
# but Postgres: no OpenRouter key, no GitHub App, no Traefik route.
BADGE_REPO="ghcr.io/kolonie-ai/kolonie-badge-runner"
WEBSITE_REPO="ghcr.io/kolonie-ai/kolonie-website"

# Which build to fetch, per image, defaulting to the mutable tag (#14).
#
# `latest` is the right default and the wrong thing to rely on. A deploy that
# always pulls it ships whatever finished building most recently, which need not
# be the commit that asked for the deploy and need not be a commit anyone
# reviewed — the whole reason a documentation-only push here was able to deliver
# an application build nobody chose. A caller that *knows* which build it pushed
# passes it here, and then what runs is a function of a commit.
#
# Per image rather than one version for all three, because the three are built by
# three workflows in two repositories and share no version. A caller sets the one
# it knows about; the other two stay on `latest` and are simply re-pulled.
API_VERSION="${API_VERSION:-}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
MODERATION_VERSION="${MODERATION_VERSION:-}"
TRIAGE_VERSION="${TRIAGE_VERSION:-}"
BADGE_VERSION="${BADGE_VERSION:-}"
WEBSITE_VERSION="${WEBSITE_VERSION:-}"

CUR_API=""
CUR_RUNNER=""
CUR_MOD=""
CUR_TRIAGE=""
CUR_BADGE=""
CUR_WEB=""
if [ -f "${STATE_DIR}/deployed.env" ]; then
    PREV_STATE=$(set -a; . "${STATE_DIR}/deployed.env"; set +a; echo "${API_IMAGE:-}|${RUNNER_IMAGE:-}|${MODERATION_IMAGE:-}|${TRIAGE_IMAGE:-}|${BADGE_IMAGE:-}|${WEBSITE_IMAGE:-}")
    CUR_API="${PREV_STATE%%|*}"
    CUR_RUNNER="$(echo "$PREV_STATE" | cut -d"|" -f2)"
    CUR_MOD="$(echo "$PREV_STATE" | cut -d"|" -f3)"
    # Empty on a host whose last record predates this service, which is every
    # host on the day this ships. resolve_image() then refuses only if nothing
    # names a version either — the same path a service deploying for the first
    # time has always taken.
    CUR_TRIAGE="$(echo "$PREV_STATE" | cut -d"|" -f4)"
    CUR_BADGE="$(echo "$PREV_STATE" | cut -d"|" -f5)"
    # Still the last field, and it must stay the last field: `##*|` is what makes
    # a record written before a service existed readable at all. A sixth image
    # goes *before* the website here, never after it.
    CUR_WEB="${PREV_STATE##*|}"
fi

# Resolve one image to the reference this deploy will fetch.
#
# Three inputs, in order of authority: the version the caller named, then what
# the last successful deploy recorded, then nothing — and nothing is a failure.
#
# **The recorded value is carried whole, not taken apart.** `deployed.env` holds
# digest references (`repo@sha256:…`), and the obvious-looking
# `${recorded#*:}` strips everything up to the first colon — which in a digest
# reference is the one inside `sha256:`. That yields the digest's hex as if it
# were a tag, and `repo:<hex>` is a tag that has never existed. It was live for
# one day: on 2026-07-31 a deploy probed
# `kolonie-verifier-runner:a1e04d9b…` and reported the image unreachable, so
# migrations were skipped as "the api is not reachable" while the api was in fact
# serving. Nothing broke, because each service's *own* pass named a real commit
# and only the other three were nonsense — but every one of those three was then
# recorded as a mutable tag, and a rollback to a tag that does not resolve is not
# a rollback.
#
# So: a digest reference is already the answer to "which build", and turning it
# back into a version discards the only part that is unambiguous.
#
# **Fatal only for an image this invocation will actually start.** It used to
# refuse for any of the five, and that made a new service impossible to introduce:
# `deploy.sh api` resolves every image, so on 2026-08-01 the first deploy carrying
# `support-triage-runner` failed on the *api* iteration — for want of a recorded
# build for a service the api deploy does not touch, several iterations before the
# one that would have recorded it. The list the caller sends is deployed in order,
# so the failure came before the fix could.
#
# `all` keeps the old behaviour, and must: `up -d` with no service named creates
# every container, so an unresolved image there really would be started from
# `:latest`. For a named service, the others are not recreated and their reference
# is never read — so an empty tag is carried, `pin()` leaves it alone, and
# `record_deployment` copies the previous record forward as it already did.
#
# What is *not* traded away: a missing build never becomes `:latest`. It becomes
# empty, and empty is inert.
required_image() {
    [ "$SERVICE" = all ] || [ "$SERVICE" = "$1" ]
}

resolve_image() {
    local named="$1" recorded="$2" repo="$3" label="$4"

    if [ -n "$named" ]; then
        if [ "$named" = latest ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${label}: the deploy names the image it intends, not :latest." >&2
            return 1
        fi
        echo "${repo}:${named}"
        return 0
    fi

    case "$recorded" in
        "${repo}@sha256:"*)
            echo "$recorded"
            return 0 ;;
        "${repo}:"*)
            # Repair the records the split above wrote while it was live.
            #
            # A recorded value of `repo:<64 lowercase hex>` is not a tag anyone
            # ever pushed — this project's tags are 40-character git SHAs and
            # `latest`, and 64 hex characters is the shape of a sha256 digest
            # that lost its `@`. Reading it back as the digest it came from turns
            # a file the next rollback would have failed on into a working one,
            # without anybody logging into the host.
            #
            # Narrow on purpose: a real 64-hex tag would be misread, and there is
            # no such tag here. If one is ever introduced this heuristic has to
            # go, and the loud line below is what will lead someone to it.
            local tag="${recorded#"${repo}":}"
            if [ ${#tag} -eq 64 ] && [[ "$tag" =~ ^[0-9a-f]+$ ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${label}: deployed.env holds ${repo}:${tag}, which is a digest that lost its '@' — reading it as one" >&2
                echo "${repo}@sha256:${tag}"
                return 0
            fi
            echo "$recorded"
            return 0 ;;
    esac

    if ! required_image "$label"; then
        # Not this deploy's business. Said once, at WARN, because a host that
        # never records this image is a real condition somebody should notice —
        # just not by having an unrelated deploy refused.
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${label}: no build recorded, and this deploy does not touch it — carrying nothing" >&2
        echo ""
        return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${label}: no version given and none recorded in ${STATE_DIR}/deployed.env." >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${label}: pass a version, or deploy this service once so a build is recorded." >&2
    return 1
}

API_IMAGE_TAG=$(resolve_image "$API_VERSION" "$CUR_API" "$API_REPO" api)
RUNNER_IMAGE_TAG=$(resolve_image "$RUNNER_VERSION" "$CUR_RUNNER" "$RUNNER_REPO" verifier-runner)
MODERATION_IMAGE_TAG=$(resolve_image "$MODERATION_VERSION" "$CUR_MOD" "$MODERATION_REPO" moderation-runner)
TRIAGE_IMAGE_TAG=$(resolve_image "$TRIAGE_VERSION" "$CUR_TRIAGE" "$TRIAGE_REPO" support-triage-runner)
BADGE_IMAGE_TAG=$(resolve_image "$BADGE_VERSION" "$CUR_BADGE" "$BADGE_REPO" badge-runner)
WEBSITE_IMAGE_TAG=$(resolve_image "$WEBSITE_VERSION" "$CUR_WEB" "$WEBSITE_REPO" website)

# Exported *now*, before anything runs `docker compose`, because compose reads
# `${API_IMAGE:-…:latest}` and would otherwise pull `latest` no matter what was
# asked for — probing one tag and pulling another is exactly the class of bug
# this file keeps having. pin() overwrites all three with digests immediately
# after the pull, so these values are only ever what gets *fetched*, never what
# gets run.
export API_IMAGE="$API_IMAGE_TAG"
export RUNNER_IMAGE="$RUNNER_IMAGE_TAG"
export MODERATION_IMAGE="$MODERATION_IMAGE_TAG"
export TRIAGE_IMAGE="$TRIAGE_IMAGE_TAG"
export BADGE_IMAGE="$BADGE_IMAGE_TAG"
export WEBSITE_IMAGE="$WEBSITE_IMAGE_TAG"

# What the last *successful* deploy shipped, as immutable digests. Written only
# after the health check passes, which is what makes it a known-good record
# rather than a log of attempts — and it is therefore still the previous build
# while a deploy is in flight, which is exactly what rollback() needs.
DEPLOYED_STATE="${STATE_DIR}/deployed.env"

# Filled in by detect_profile(). Empty means infrastructure only.
PROFILE_ARGS=()
# Whether every application image was reachable. False means the compose view
# this run is working from is *incomplete*, and deploy() must not treat it as
# authoritative — see the note on --remove-orphans there.
PROFILES_COMPLETE=true
# Whether the api image could be pulled. migrate() needs to know: it runs the
# migrations *out of that image*, so "no api image" and "no migration step" are
# the same condition, not two.
API_AVAILABLE=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Authenticate against GHCR.
#
# **All five application images are public since 2026-08-01 (#58)**, and the
# organisation now allows public packages by default, so the sixth will be too.
#
# This login is therefore no longer required to pull them, and it stays because a
# login that is unnecessary is not a login that fails: it still authenticates the
# rate limit, and it is what a private package would need if one is ever added
# deliberately. Nothing below has to change for either case.
#
# What it removes is the failure it was written under. A package created by a
# build was private and linked only to the repository that pushed it, so a deploy
# triggered from *this* repository answered 403 — and carried on, leaving the
# service on a stale image while reporting success. Public packages make that
# unreachable rather than merely fixed. AGENTS.md §8 keeps the history.
#
# GHCR_TOKEN is the workflow's own GITHUB_TOKEN, forwarded over SSH. It expires
# with the job, so nothing long-lived is stored on this host. It only reaches the
# packages if kolonie-infra has been granted read access to them in the package
# settings — see kolonie-infra#1.
ghcr_login() {
    if [ -z "${GHCR_TOKEN:-}" ]; then
        log "WARN: no GHCR_TOKEN forwarded — application images cannot be pulled"
        return
    fi

    if echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-x-access-token}" --password-stdin >/dev/null 2>&1; then
        log "GHCR: authenticated"
    else
        log "WARN: GHCR login failed — application images cannot be pulled"
    fi
}

ghcr_logout() {
    docker logout ghcr.io >/dev/null 2>&1 || true
}

# Decide what can actually be deployed, by asking the registry rather than by
# reading a flag someone has to remember to flip.
#
# Each profile is probed on its own. One unreachable image must never stop the
# others from deploying: `docker compose pull` fails the whole command for a
# single missing image, and that is exactly how the unbuilt website image took
# api and verifier-runner down with it (#1).
detect_profile() {
    PROFILE_ARGS=()

    if docker pull -q "$API_IMAGE_TAG" >/dev/null 2>&1; then
        PROFILE_ARGS+=(--profile full)
        API_AVAILABLE=true
        log "Application images reachable — including --profile full"
    else
        PROFILES_COMPLETE=false
        log "WARN: $API_IMAGE_TAG is not reachable."
        log "WARN: api.kolonie.ai, academy.kolonie.ai, mcp.kolonie.ai, challenge.kolonie.ai and console.kolonie.ai will answer 502."
    fi

    if docker pull -q "$WEBSITE_IMAGE_TAG" >/dev/null 2>&1; then
        PROFILE_ARGS+=(--profile website)
        log "Website image reachable — including --profile website"
    else
        PROFILES_COMPLETE=false
        log "WARN: $WEBSITE_IMAGE_TAG is not reachable. kolonie.ai will answer 502."
        log "WARN: the image builds in kolonie-website; the repository whose token"
        log "WARN: is running this deploy may need read access to the package"
        log "WARN: under Manage Actions access."
    fi

    if [ ${#PROFILE_ARGS[@]} -eq 0 ]; then
        log "WARN: no application images reachable — deploying infrastructure only."
    fi

    # pgAdmin (#30), and the gate is the host's .env rather than the registry.
    #
    # The two probes above ask a registry whether an image exists, because that
    # is what can be missing for an image this project builds. What can be
    # missing here is different: dpage/pgadmin4 is always pullable, and what a
    # host may not have is PGADMIN_PASSWORD. Without it the container's entrypoint
    # refuses to start, it crash-loops, healthcheck() reads three restarts and
    # rolls the entire stack back — so an admin console nobody set up would break
    # every kolonie-platform deploy. That is #7 and #93's shape, and this is the
    # cheapest place to make it impossible rather than merely unlikely.
    #
    # So the profile is opt-in by configuration: define PGADMIN_PASSWORD on the
    # host and pgAdmin is pulled, started and health-checked with everything
    # else; leave it out and the service is not in the compose view at all.
    #
    # **A name, never a value.** Same standard as preflight_env() and
    # scripts/env-drift.sh: this runs in a workflow whose log is public.
    if grep -qE '^PGADMIN_PASSWORD=.' "$DEPLOY_DIR/.env" 2>/dev/null || [ -n "${PGADMIN_PASSWORD:-}" ]; then
        PROFILE_ARGS+=(--profile admin)
        log "PGADMIN_PASSWORD is set on this host — including --profile admin"
    else
        log "PGADMIN_PASSWORD is not set on this host — skipping --profile admin (db.kolonie.ai stays down)"
    fi
}

# Snapshot the current state, for reading afterwards.
#
# **This is diagnostic, not a recovery input.** Since #12, rollback() returns to
# the digests in state/deployed.env; it does not restore this file. What is
# written here is a rendering of the configuration, and a configuration is not a
# build — restoring it while every image was `:latest` brought back the same
# image that had just failed.
#
# Still runs *after* detect_profile(): `config` without the profile arguments
# silently omits every profiled service, and a snapshot of a five-service host
# that lists two is worse than no snapshot at all. That omission is what made the
# 2026-07-28 rollback delete api, verifier-runner and website.
backup() {
    log "Creating backup..."
    mkdir -p "$BACKUP_DIR"
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" ps --format json > "$BACKUP_DIR/ps_${TIMESTAMP}.json" 2>/dev/null || true
    # `--no-interpolate` is the whole point of this line, not a detail.
    #
    # Without it `config` resolves every ${VAR} against .env — so this wrote
    # JWT_SECRET, POSTGRES_PASSWORD, CLOUDFLARE_API_TOKEN, HCAPTCHA_SECRET and
    # GITHUB_VERIFIER_TOKEN in cleartext, mode 664, into a git checkout of a
    # public repository, on every single deploy (#27). Nothing published it —
    # deploy.sh uses fetch and reset --hard, which do not stage untracked files —
    # but it sat one `git add -A` away from being published, in a directory
    # agents are expected to work in.
    #
    # Nothing reads this file. rollback.sh mentions it only to say it
    # deliberately does not use it, so leaving the values unresolved costs a
    # diagnostic nicety and removes a standing exposure. The placeholders are
    # still there, and .env is still on the host if you need to resolve one.
    umask 077
    docker compose "${PROFILE_ARGS[@]}" -f "$DEPLOY_DIR/docker-compose.yml" config --no-interpolate \
        > "$DEPLOY_DIR/docker-compose.last.yml" 2>/dev/null || true
    chmod 600 "$DEPLOY_DIR/docker-compose.last.yml" 2>/dev/null || true
    umask 022
}

# Pull new images
pull() {
    log "Pulling latest images..."
    cd "$DEPLOY_DIR"
    if [ "$SERVICE" = "all" ]; then
        local services
        services=$(docker compose "${PROFILE_ARGS[@]}" config --services 2>/dev/null)
        for svc in $services; do
            docker compose "${PROFILE_ARGS[@]}" pull "$svc" 2>&1 || {
                log "WARN: Failed to pull $svc (will continue with existing image if any)"
            }
        done
    else
        docker compose "${PROFILE_ARGS[@]}" pull "$SERVICE" 2>&1 || {
            log "ERROR: Image pull failed"
            exit 1
        }
    fi
}

# Turn each freshly pulled tag into the digest it resolved to, and run *that*.
#
# `:latest` answers a different question every time it is asked. Between the
# pull and the `up -d` a new build can land, and then the containers that start
# are not the ones this deploy inspected — nothing in the log would say so. Worse,
# after the deploy nothing anywhere records which build is serving, so rollback()
# had no previous version to return to and `up -d` after a bad deploy pulled the
# same bad image straight back (#12).
#
# `RepoDigests` is filled by the pull itself, so this is the digest the registry
# just served rather than a second question that could get a second answer.
#
# A tag that cannot be resolved keeps its tag and logs it. Falling back is right
# here: the deploy is no worse than it was before pinning existed, and refusing
# to deploy over a missing digest would turn an audit-trail gap into an outage.
pin() {
    log "Pinning images to the digests just pulled..."
    API_IMAGE=$(digest_of "$API_IMAGE_TAG" "$API_REPO")
    RUNNER_IMAGE=$(digest_of "$RUNNER_IMAGE_TAG" "$RUNNER_REPO")
    MODERATION_IMAGE=$(digest_of "$MODERATION_IMAGE_TAG" "$MODERATION_REPO")
    TRIAGE_IMAGE=$(digest_of "$TRIAGE_IMAGE_TAG" "$TRIAGE_REPO")
    BADGE_IMAGE=$(digest_of "$BADGE_IMAGE_TAG" "$BADGE_REPO")
    WEBSITE_IMAGE=$(digest_of "$WEBSITE_IMAGE_TAG" "$WEBSITE_REPO")
    export API_IMAGE RUNNER_IMAGE MODERATION_IMAGE TRIAGE_IMAGE BADGE_IMAGE WEBSITE_IMAGE

    log "  api:                   $API_IMAGE"
    log "  verifier-runner:       $RUNNER_IMAGE"
    log "  moderation-runner:     $MODERATION_IMAGE"
    log "  support-triage-runner: $TRIAGE_IMAGE"
    log "  badge-runner:          $BADGE_IMAGE"
    log "  website:               $WEBSITE_IMAGE"
}

# The digest a local image carries for its own repository, or the tag if it has
# none. Matched on the repository prefix: an image may carry digests for several
# repositories, and the one from a different repository is not this one's version.
# Note the `>&2` on the warning. This function's *stdout is its return value* —
# the caller reads it through a command substitution — so a log line written to
# stdout would be captured as part of the image reference and end up in both the
# exported variable and the recorded state file. It did, until a rehearsal
# against a stub docker showed a `WEBSITE_IMAGE=` line with a timestamped warning
# inside it.
digest_of() {
    local tag="$1" repo="$2" digest

    # An image this deploy is not touching and has never recorded. Nothing to
    # resolve and nothing to warn about — see required_image().
    [ -z "$tag" ] && { echo ""; return 0; }
    digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$tag" 2>/dev/null \
        | grep "^${repo}@" | head -n 1 || true)

    if [ -z "$digest" ]; then
        log "WARN: no digest recorded for $tag — deploying the mutable tag, and it will not be rollback-able" >&2
        echo "$tag"
    else
        echo "$digest"
    fi
}

# Record what is now serving, once it has proved it serves.
#
# After the health check, never before: a file written at the start of a deploy
# records an intention, and rollback() would then restore the build that had just
# failed. Written afterwards, this file only ever names a build that answered.
record_deployment() {
    mkdir -p "$STATE_DIR"

    # Only the services this deploy actually touched.
    #
    # This used to write all three unconditionally, which was correct while every
    # deploy was `all`. Since #14 a build in kolonie-platform deploys one service,
    # and the other two are then *not pulled* — so pin() resolves their digests
    # from whatever local tag happens to be lying around, which is the previous
    # build. Writing those would record images that are not running, and
    # rollback() would "return" to a build this host never served.
    #
    # It happened on 2026-07-29: an api deploy correctly recorded the new digest,
    # and the verifier-runner deploy queued behind it overwrote API_IMAGE with the
    # stale local `:latest`, while the api container went on running the new one.
    local recorded_api="${API_IMAGE}" recorded_runner="${RUNNER_IMAGE}"
    local recorded_moderation="${MODERATION_IMAGE}" recorded_triage="${TRIAGE_IMAGE}"
    local recorded_badge="${BADGE_IMAGE}"
    local recorded_website="${WEBSITE_IMAGE}"

    if [ "$SERVICE" != all ] && [ -f "$DEPLOYED_STATE" ]; then
        # Read the previous record in a subshell, so sourcing it cannot clobber
        # the variables this deploy just resolved.
        local previous
        previous=$(set -a; . "$DEPLOYED_STATE"; set +a; echo "${API_IMAGE}|${RUNNER_IMAGE}|${MODERATION_IMAGE}|${TRIAGE_IMAGE}|${BADGE_IMAGE}|${WEBSITE_IMAGE}")
        [ "$SERVICE" != api ]                   && recorded_api="${previous%%|*}"
        [ "$SERVICE" != verifier-runner ]       && recorded_runner="$(cut -d'|' -f2 <<<"$previous")"
        [ "$SERVICE" != moderation-runner ]     && recorded_moderation="$(cut -d'|' -f3 <<<"$previous")"
        [ "$SERVICE" != support-triage-runner ] && recorded_triage="$(cut -d'|' -f4 <<<"$previous")"
        [ "$SERVICE" != badge-runner ]          && recorded_badge="$(cut -d'|' -f5 <<<"$previous")"
        [ "$SERVICE" != website ]               && recorded_website="${previous##*|}"
    fi

    local infra_commit; infra_commit=$(git rev-parse HEAD 2>/dev/null || echo ""); cat > "$DEPLOYED_STATE" <<EOF
INFRA_COMMIT=${infra_commit}
# Written by scripts/deploy.sh after a successful health check.
# These are the images currently serving. rollback() returns to them.
# Do not edit by hand: a wrong digest here is a rollback into an unknown build.
# A single-service deploy rewrites only its own line; the others are carried
# over from the previous record, because it did not pull them and cannot know.
DEPLOYED_AT=${TIMESTAMP}
API_IMAGE=${recorded_api}
RUNNER_IMAGE=${recorded_runner}
MODERATION_IMAGE=${recorded_moderation}
TRIAGE_IMAGE=${recorded_triage}
BADGE_IMAGE=${recorded_badge}
WEBSITE_IMAGE=${recorded_website}
EOF
    log "Recorded the deployed build in ${DEPLOYED_STATE} (service: ${SERVICE})"

    # This file exists so a rollback goes to a build somebody chose. A line
    # holding a *tag* rather than a digest defeats that entirely: `:latest`
    # resolves to whatever it points at on the day of the rollback, which is the
    # failure #12 removed and which came back on 2026-07-29 as
    # `MODERATION_IMAGE=…:latest` — written because a service deploying for the
    # first time had no previous record to carry forward and no digest of its
    # own.
    #
    # It is a warning and not a failure, deliberately. The deploy has already
    # passed its health check by the time this runs, so exiting non-zero here
    # would paint a working deploy red — and #31 is largely a complaint about
    # runs whose colour misdescribes what happened. The bookkeeping is what is
    # broken, and this says so where it is broken.
    local recorded name value untagged=
    for recorded in "API_IMAGE=${recorded_api}" "RUNNER_IMAGE=${recorded_runner}" \
                    "MODERATION_IMAGE=${recorded_moderation}" "TRIAGE_IMAGE=${recorded_triage}" \
                    "BADGE_IMAGE=${recorded_badge}" \
                    "WEBSITE_IMAGE=${recorded_website}"; do
        name="${recorded%%=*}"
        value="${recorded#*=}"
        [ -z "$value" ] && continue
        case "$value" in
            *@sha256:*) ;;
            *) untagged="${untagged:+$untagged }${name}" ;;
        esac
    done

    if [ -n "$untagged" ]; then
        log "ERROR: ${DEPLOYED_STATE} records a mutable tag where a digest belongs: ${untagged}"
        log "ERROR: rollback() cannot return to a tag — it resolves to whatever it points at then, not to this build"
        log "ERROR: the deploy itself succeeded; what is broken is the record of it"
    fi
}

# Apply pending database migrations — after the pull, before the switch.
#
# The order is the whole point. An API answering against a schema one migration
# behind is worse than an API that is briefly down: it fails per request, only
# on the paths that touch the new columns, and only for some callers. So the
# database is brought to the schema the new image expects *before* that image
# starts serving.
#
# It is a one-shot container from the api image, which carries packages/db and
# its SQL for exactly this (kolonie-platform's apps/api/Dockerfile says so).
# A separate kolonie-migrate image is the tidier idea and a third image to
# build, push, version and keep in step for a step that runs for two seconds —
# worth revisiting when migrations need a toolchain the API does not have.
#
# Not --no-deps: `run` then honours the api service's `depends_on postgres:
# service_healthy`, and a migration that waits for the database to be ready
# beats one that races it. Postgres carries no profile and is already up, so in
# the normal case this waits for nothing.
#
# A failure here exits without rollback(), and that is deliberate. Nothing has
# been switched yet: the previous containers are still running and still
# serving. rollback() restores a *configuration*, which is precisely what has
# not changed — calling it would replace a clean abort with an unnecessary
# `up -d` against containers that are already correct.
migrate() {
    if [ "$API_AVAILABLE" != true ]; then
        log "Migrations: skipped — $API_IMAGE is not reachable, and the migrator ships in it"
        return
    fi

    if [ "$SERVICE" != "all" ] && [ "$SERVICE" != "api" ]; then
        log "Migrations: skipped — this deploy touches $SERVICE only"
        return
    fi

    log "Applying database migrations..."
    cd "$DEPLOY_DIR"
    # -T: there is no terminal on the far end of the deploy workflow's SSH
    # session, and compose only allocates one when asked.
    if ! docker compose "${PROFILE_ARGS[@]}" run --rm -T api npm run migrate -w @kolonie-ai/db 2>&1; then
        log "ERROR: migration failed — the deploy stops here."
        log "ERROR: no new container was started; the previous ones are still serving."
        log "ERROR: the database may be partly migrated. See docs/disaster-recovery.md, Scenario 5."
        exit 1
    fi
    verify_migrations
    log "Migrations: done"
}

# Did the migrations that shipped in this image actually reach the database?
#
# **The migrator answers this too, and this asks it a second way on purpose.**
# The migrator compares the journal against the
# bookkeeping table by hash and exits non-zero when they disagree — which covers
# every path, including a developer's laptop. What it cannot cover is the case
# where the *image* is not the one this deploy pulled: a container built two
# commits ago is internally consistent, reports `none pending`, and is wrong
# about the only thing that matters here.
#
# So this compares the `.sql` files in the image against the rows in the
# database, from outside both. It costs one `ls` and one `select` on a step that
# already takes half a minute.
#
# It happened on 2026-08-03: five migrations never ran, three deploys reported
# success, and the fourth failed in the seed — two steps from the cause. See
# docs/disaster-recovery.md, Scenario 6.
verify_migrations() {
    local in_image in_database
    in_image=$(docker compose "${PROFILE_ARGS[@]}" run --rm -T --entrypoint sh api \
        -c 'ls /app/packages/db/drizzle/*.sql 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
    # The credentials come from inside the container rather than from this
    # shell: `.env` is read by compose and never sourced here, so
    # `${POSTGRES_USER}` out here is an empty string that psql would quietly
    # turn into a connection as `root`.
    in_database=$(docker compose "${PROFILE_ARGS[@]}" exec -T postgres sh -c \
        'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from drizzle.__drizzle_migrations"' \
        2>/dev/null | tr -dc '0-9')

    # Either number missing means the check could not run — a container that is
    # not up, a psql that is not there. That is not a failed migration and must
    # not be reported as one; the migrator has already had its say.
    if [ -z "$in_image" ] || [ -z "$in_database" ]; then
        log "WARN: could not count migrations (image='$in_image' database='$in_database') — skipping the cross-check"
        return
    fi

    # **Asymmetric, and the asymmetry is the whole design.**
    #
    # More in the image than in the database means migrations that shipped in
    # this build did not run. That is the failure this exists for, and it stops
    # the deploy.
    #
    # More in the database than in the image is the ordinary case on a board two
    # agents work: somebody else's migration landed and this build predates it.
    # The schema is ahead of the code, every migration here is additive, and a
    # deploy refused for that would block the normal interleaving of two
    # contributors. It is worth a line in the log and nothing more.
    if [ "$in_image" -gt "$in_database" ]; then
        log "ERROR: the image carries $in_image migrations and the database has applied $in_database."
        log "ERROR: the deploy stops here — the schema this build expects is not the schema that exists."
        log "ERROR: no new container was started; the previous ones are still serving."
        log "ERROR: see docs/disaster-recovery.md, Scenario 6, for how to find and repair the gap."
        exit 1
    fi

    if [ "$in_image" -lt "$in_database" ]; then
        log "Migrations: $in_database applied, $in_image in this image — the database is ahead, which is somebody else's migration having landed first"
        return
    fi

    log "Migrations: $in_database applied, matching the $in_image this image carries"
}

# Put the Academy tasks in the database — same window as migrate(), same reason.
#
# `GET /v1/tasks` reads a table that migrations create and nothing fills. Without
# this step the endpoint answers with an empty list, and the MVP loop that
# ROADMAP.md measures the Colony against — "registers, fetches a task, submits a
# result, and a coin lands in the ledger" — has nothing to fetch at step two.
#
# Re-running it is safe by construction: each task is matched on a fixed id and
# upserted, so a second run rewrites wording and rewards rather than duplicating
# rows. It never deletes; a task the Colony has paid out against cannot vanish
# without taking its audit trail with it. See packages/db/src/academy-tasks.ts.
#
# Same failure handling as migrate(), and for the same reason: nothing has been
# switched yet, so an abort here leaves the previous containers serving. The one
# statement it runs is atomic, so a failure means nothing was seeded rather than
# half of it.
seed() {
    if [ "$API_AVAILABLE" != true ]; then
        log "Academy tasks: skipped — $API_IMAGE is not reachable, and the seed ships in it"
        return
    fi

    if [ "$SERVICE" != "all" ] && [ "$SERVICE" != "api" ]; then
        log "Academy tasks: skipped — this deploy touches $SERVICE only"
        return
    fi

    log "Seeding Academy tasks..."
    cd "$DEPLOY_DIR"
    if ! docker compose "${PROFILE_ARGS[@]}" run --rm -T api npm run seed -w @kolonie-ai/db 2>&1; then
        log "ERROR: seeding failed — the deploy stops here."
        log "ERROR: no new container was started; the previous ones are still serving."
        exit 1
    fi
    log "Academy tasks: done"
}

# Deploy
#
# **`--remove-orphans` is conditional, and the condition is the lesson from
# 2026-07-28.** That flag deletes every container absent from the compose view it
# is given, and a profile that was dropped because its image could not be pulled
# makes that view incomplete rather than authoritative. rollback() already
# refuses the flag outright for this reason; deploy() earns it only when the view
# is complete.
#
# Two ways the view is incomplete, and both got worse when kolonie-platform
# started triggering deploys (#14):
#
#  - **A named service.** `up -d --remove-orphans api` still removes containers
#    for services outside the profile view, so a deploy of one service could
#    delete another. A single-service deploy has no business asserting what the
#    whole host should contain.
#  - **An unreachable image.** The deploy now runs under the token of whichever
#    repository triggered it. kolonie-platform can read its own packages and need
#    not be able to read the website's — so a perfectly good website container
#    would look like an orphan to an api deploy, and be removed.
#
# When the flag is withheld, a genuinely removed service leaves a container
# behind. That is a stale container, which is visible and fixable; the
# alternative is an outage, which is neither.

deploy() {
    log "Deploying service: $SERVICE"
    cd "$DEPLOY_DIR"

    local orphan_args=()
    if [ "$SERVICE" = "all" ] && [ "$PROFILES_COMPLETE" = true ]; then
        orphan_args=(--remove-orphans)
    else
        log "Not passing --remove-orphans: $([ "$SERVICE" != all ] && echo "deploying $SERVICE only" || echo "an application image was unreachable, so the compose view is incomplete")"
    fi

    if [ "$SERVICE" = "all" ]; then
    if [ -n "${INFRA_COMMIT:-}" ]; then
        log "Returning /opt/kolonie to commit $INFRA_COMMIT..."
        git reset --hard "$INFRA_COMMIT"
    fi

        docker compose "${PROFILE_ARGS[@]}" up -d "${orphan_args[@]+"${orphan_args[@]}"}" 2>&1 || {
            log "ERROR: Deployment failed"
            rollback
            exit "$(failure_exit_code)"
        }
    else
    if [ -n "${INFRA_COMMIT:-}" ]; then
        log "Returning /opt/kolonie to commit $INFRA_COMMIT..."
        git reset --hard "$INFRA_COMMIT"
    fi

        docker compose "${PROFILE_ARGS[@]}" up -d "${orphan_args[@]+"${orphan_args[@]}"}" "$SERVICE" 2>&1 || {
            log "ERROR: Deployment failed"
            rollback
            exit "$(failure_exit_code)"
        }
    fi

    # Last, and inside deploy() rather than beside it: whatever compose has just
    # started is current by definition, so this only ever asks about the
    # containers it left alone (#84).
    recreate_stale_mounted_config
}

# The configuration change compose cannot see (#84)
#
# Compose recreates a container when *its own definition* changes — image,
# command, environment, the mounts themselves. A file read *through* a bind mount
# is not part of that definition, so editing one changes nothing: the new file
# lands on the host, `up -d` reports success, and the container carries on
# running the configuration it parsed at startup. Reproduced twice on 2026-08-05,
# deploying #80 and then the fix in 7a28bac; both times the pipeline took effect
# only when the container was recreated by hand.
#
# **A deploy that reports success and changes nothing is the worst shape of
# failure this repository has**, and it is the shape #7 had: the run is green,
# the file on disk is right, and the behaviour is the old one. There is nothing
# to notice.
#
# **The comparison is the file's mtime against the container's StartedAt, and it
# has to be.** Comparing *contents* is the obvious version and it cannot work: a
# bind-mounted file inside the container is the same inode as the file on the
# host, so the two are identical by construction, before and after. What is stale
# is never the file — it is the process that read it once. So the only question
# available is whether this container is older than its configuration.
#
# **The set of files is read off the containers rather than listed here.** A
# hand-kept list of "services with mounted configuration" is the copy that goes
# quietly out of step — the failure #120 is named for — and it would have to be
# edited by whoever adds the next mounted file, who has no reason to look in this
# function. `docker inspect` already knows: a bind mount whose source is a
# regular file is configuration read through a mount, and one whose source is a
# directory or a socket is not.
#
# What that catches today is Promtail's pipeline, Loki's configuration, Traefik's
# **static** file and pgadmin's server list — but that is an observation, not
# something this function depends on. Traefik's `dynamic/` directory is excluded
# by being a directory, which is the right answer for the right reason: Traefik
# watches those files itself and reloads them, and its static one it does not.
#
# **Deliberately after the deploy's own `up -d`.** Whatever compose recreated for
# its own reasons has just started and therefore cannot be older than its
# configuration, so it never appears here. Only the containers compose left
# alone are asked, and a service is recreated at most once per deploy.
#
# **What this widens, said plainly rather than discovered later.** Until now a
# broken `promtail.yml` was a no-op, because the container that would have
# rejected it was never restarted. It is now a deploy-blocking failure like any
# other: the recreated container is checked by healthcheck() along with
# everything else, and an unhealthy one rolls the deploy back. That is the
# existing contract for every service in the profile view and this change does
# not carve an exception into it — a configuration that cannot start is a defect,
# and the whole point of the issue is that such a defect stops being invisible.
recreate_stale_mounted_config() {
    cd "$DEPLOY_DIR"

    local services svc container started started_at source dest
    local stale=()

    services=$(docker compose "${PROFILE_ARGS[@]}" config --services 2>/dev/null || true)

    for svc in $services; do
        container="kolonie-${svc}"

        # A container that does not exist has nothing to be older than. That is
        # the normal case for a service being introduced, and for every service
        # outside this deploy's reach on a host that has never run it.
        started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null || true)
        [ -n "$started_at" ] || continue
        started=$(date -d "$started_at" +%s 2>/dev/null || true)
        case "${started:-}" in ''|*[!0-9]*) continue ;; esac

        while IFS='|' read -r source dest; do
            [ -n "$source" ] || continue
            [ -f "$source" ] || continue
            [ "$(stat -c %Y "$source" 2>/dev/null || echo 0)" -gt "$started" ] || continue
            log "$svc: $source is newer than the container, which started at $started_at"
            log "$svc: it is mounted at $dest and was read once, at startup — so the running configuration is the old one"
            stale+=("$svc")
            break
        done < <(docker inspect --format='{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' "$container" 2>/dev/null || true)
    done

    if [ "${#stale[@]}" -eq 0 ]; then
        log "Mounted configuration: every container is at least as new as the files it reads."
        return 0
    fi

    log "Recreating ${stale[*]} — a change inside a bind mount is invisible to compose, so nothing else would."
    docker compose "${PROFILE_ARGS[@]}" up -d --force-recreate "${stale[@]}" 2>&1 || {
        log "ERROR: could not recreate ${stale[*]} after a mounted configuration change"
        rollback
        exit "$(failure_exit_code)"
    }
}


# The label through which an application image declares what it cannot start
# without (#42).
#
# The 2026-07-31 outage: kolonie-platform#93 made `BAN_MARK_SALT` mandatory —
# `packages/db` throws at startup without it, deliberately — and the variable
# reached this repository nowhere. Not docker-compose.yml, not .env.example, not
# the host's .env. `scripts/env-drift.sh` could not see it either, and its own
# header says why: all three of its lists are seeded from what compose already
# reads, so a variable compose has never heard of is invisible to every one of
# them. Twelve and a half hours, nineteen deploys, each rolling back.
#
# Stated generally, and this is the part worth keeping: **a repository that makes
# a variable mandatory has changed the deploy contract of a repository it cannot
# see.** #42 lists three places that hand-off could live. This is option A, the
# image answering for itself: no shared file, no cross-repo path, nothing to keep
# in sync, and it works for an image built from a repository this one has never
# heard of. The declaration ships inside the same artefact as the code that
# throws, so it cannot drift from it.
#
# A label rather than a command in the image, because reading it neither starts
# the application nor needs its entrypoint to be sane — and a preflight that runs
# the very build it is meant to vet has the failure inside the check.
#
# The emitting half is kolonie-platform#75.
REQUIRED_ENV_LABEL="ai.kolonie.required-env"

# What one image says it requires. Empty for an image that says nothing, which
# is every image built before #75 — those must keep deploying, or this check is
# itself the outage.
declared_env() {
    local out
    # Measured against Docker 29.1.3 on 2026-07-31, over four images: no labels
    # at all, labels without this one, this label, and an image that is not on
    # the host. The first three render an **empty string** and exit 0; the fourth
    # exits non-zero. `<no value>` and `map[]` are what a bare Go template does
    # with an absent key and a nil map — Docker's formatter swallows both today,
    # but they are cheap to tolerate and this script has to survive whatever
    # Docker the host is on.
    out=$(docker image inspect --format "{{index .Config.Labels \"$REQUIRED_ENV_LABEL\"}}" "$1" 2>/dev/null) || return 0
    case "$out" in "<no value>"|"map[]"|"") return 0 ;; esac
    # Comma- or whitespace-separated, so both spellings of the label work.
    printf '%s' "$out" | tr ',[:space:]' '\n\n' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || true
}

# Refuse a deploy whose images require something this host does not provide.
#
# Runs after pin() — the images are on the host, so their labels are readable —
# and before migrate(), which is the first step that starts a container from one
# of them. Nothing has moved when this fails, which is the whole point: the
# 2026-07-31 outage reached production because the failing path was the deployed
# one.
#
# **A variable can arrive two ways, and only one of them involves .env.**
#
#   1. compose *assigns* it a value in an `environment:` block, as
#      `DATABASE_URL: postgresql://kolonie:${POSTGRES_PASSWORD}@postgres:5432/…`
#      — the name is built here and never appears in .env at all. Whether the
#      interpolations *inside* that value resolve is scripts/env-drift.sh's
#      question, not this one.
#   2. compose *passes it through*, as `BAN_MARK_SALT: ${BAN_MARK_SALT}`, and
#      then .env or the deploy environment has to define it or it arrives empty.
#
# Requiring both of every variable was the first version of this check and it was
# wrong: DATABASE_URL is case 1 for all three services, so it would have refused
# every deploy from the moment it shipped. That is the failure this check has to
# avoid above all others — a preflight that blocks good deploys is one somebody
# switches off, and then it is not there for the deploy it was written for.
# `BAN_MARK_SALT` on 2026-07-31 was neither case: absent from the compose file
# entirely, which is what "invisible" meant.
#
# What this deliberately does not prove: that the variable reaches the *right*
# service. It checks that compose mentions the name somewhere, not that the
# service declaring it lists it under its own `environment:`. Rendering the
# per-service environment would mean `docker compose config`, whose output
# carries every value — and this runs in a workflow whose log is public.
#
# **Names only, never a value**, for that same reason. `scripts/env-drift.sh`
# states the standard in its own header: adding a value to the output here
# publishes a production secret somewhere it cannot be unpublished.
preflight_env() {
    local compose_file="$DEPLOY_DIR/docker-compose.yml"
    local env_file="$DEPLOY_DIR/.env"
    local pair image svc name compose_vars compose_assigned provided declared missing report

    log "Checking the images' declared environment against this host..."

    if [ ! -f "$compose_file" ]; then
        log "WARN: no $compose_file — skipping the declared-environment check"
        return 0
    fi

    # Case 2: the names compose interpolates.
    compose_vars=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$compose_file" | sed 's/\${//' | sort -u)
    # Case 1: the names compose assigns, in either `KEY: value` or `- KEY=value`
    # form. Restricted to SHOUTING_CASE so the structural keys of the document —
    # `image:`, `ports:`, a service's own name — cannot be read as variables.
    compose_assigned=$(grep -oE '^[[:space:]]*-?[[:space:]]*[A-Z][A-Z0-9_]*[:=]' "$compose_file" \
                        | tr -d ' -:=' | sort -u)

    # What compose will interpolate from: its .env file, plus the environment
    # this script runs in, which wins over the file. Names only.
    provided=$( { [ -f "$env_file" ] && grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" | tr -d '='
                  printenv | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d '='
                } | sort -u )

    report=""
    for pair in "api:$API_IMAGE" "verifier-runner:$RUNNER_IMAGE" \
                "moderation-runner:$MODERATION_IMAGE" "support-triage-runner:$TRIAGE_IMAGE" \
                "badge-runner:$BADGE_IMAGE" \
                "website:$WEBSITE_IMAGE"; do
        svc="${pair%%:*}"
        image="${pair#*:}"
        [ -z "$image" ] && continue

        declared=$(declared_env "$image")
        [ -z "$declared" ] && continue

        while read -r name; do
            [ -z "$name" ] && continue
            missing=""
            # **Interpolation is tested first, and the order is load-bearing.**
            # `BAN_MARK_SALT: ${BAN_MARK_SALT}` is both assigned and
            # interpolated, so a check that asked "is it assigned?" first would
            # call it satisfied and wave through the exact failure this exists
            # for. Only a name that compose never interpolates is case 1.
            if printf '%s\n' "$compose_vars" | grep -qx "$name"; then
                # Case 2: compose passes it through, so something must define it.
                printf '%s\n' "$provided" | grep -qx "$name" || \
                    missing="passed through by docker-compose.yml but not defined in .env or the deploy environment"
            elif printf '%s\n' "$compose_assigned" | grep -qx "$name"; then
                # Case 1: compose builds the value itself. Nothing more is owed.
                :
            else
                missing="not set by docker-compose.yml at all — the container would never see it"
            fi
            [ -n "$missing" ] && report="$report
  $name — required by $svc, $missing"
        done <<<"$declared"
    done

    if [ -n "$report" ]; then
        log "ERROR: an image requires a variable this host does not provide:$report"
        log "Nothing has been recreated — the build that was serving is still serving."
        log "Add the variable to docker-compose.yml, .env.example and the host's .env, then deploy again."
        exit 1
    fi

    log "OK: every variable the images declare is provided"
}

# Wait for every deployed service to become healthy.
#
# The old version slept ten seconds and judged once. That is wrong twice:
#
#  - Ten seconds is shorter than the `start_period` of every application
#    service, so a perfectly good container is judged while it is still coming
#    up. Deploys then fail for timing reasons rather than for real ones.
#  - It counted `starting` as a pass, so a container that never becomes healthy
#    sails through as long as it is slow enough. The two errors point in
#    opposite directions and hid each other.
#
# So: poll until everything is healthy, or until the deadline. A verdict is
# reached only at the deadline, because a container that is briefly unhealthy
# and then recovers has not failed — it has started.
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}

# How many lines of a failing container's own log to quote, and how wide.
#
# 40 lines is a judgement: enough to carry a startup exception with its stack,
# short enough that a reader finds it. The width cap is not cosmetic — a service
# that dies while printing a serialised object emits single lines of many
# kilobytes, and one of those buries the message underneath it.
HEALTH_LOG_LINES=${HEALTH_LOG_LINES:-40}
HEALTH_LOG_COLS=${HEALTH_LOG_COLS:-500}
# A diagnostic probe must not consume the rollback window if the container has
# stopped answering. Docker's configured checks allow ten seconds today; five is
# enough for one local request whose purpose is only to preserve the response.
HEALTH_PROBE_TIMEOUT=${HEALTH_PROBE_TIMEOUT:-5}

# When a crash loop is treated as decided, rather than waited out.
#
# `restart: unless-stopped` means a container that throws on its first line never
# reaches `exited` — Docker restarts it, with a backoff, until the deploy gives
# up at HEALTH_TIMEOUT. So the terminal signal is not the state, it is the
# restart *count*: a process that has already died three times has answered the
# question, and the remaining wait cannot change the answer. Three restarts take
# roughly seven seconds of backoff, against 180 seconds of waiting for a verdict
# that is already in.
#
# Set to 0 to disable and always wait the full timeout.
EARLY_FAIL_RESTARTS=${EARLY_FAIL_RESTARTS:-3}

# The cascade re-deploy, and how a run says which half of itself failed (#79).
#
# **A deploy that failed only in its cascade reports the same red as one that
# never reached the host**, and the difference is exactly what a maintainer needs
# in order to decide whether production is serving the new build. On 2026-08-05
# eleven consecutive runs were red this way: migrations applied, the api healthy,
# `deployed.env` written — and the run-level conclusion said failure, because the
# re-deploy of a service a *previous* run had rolled back failed again on the
# same broken image.
#
# So the two are told apart in three places: a distinct exit code, a block that
# states plainly what did succeed, and a bound on how many times the same image
# is retried.
IN_CASCADE=0
CASCADE_ATTEMPTS=0

# What exit code a failure inside the cascade uses.
#
# Non-zero either way — the run did not do everything it set out to do, and
# #79 is explicit that a non-zero exit is still right. `3` rather than `1` so
# that the two are distinguishable by something a machine can read, next to the
# block that makes them distinguishable to a person.
CASCADE_EXIT_CODE=3

# How many times the same rolled-back image is re-deployed before the cascade
# gives up on it.
#
# **A cascade that has failed on the same image three times will not succeed on
# the fourth**, and until it stops it makes every unrelated deploy red — which is
# how eleven good deploys came to look like eleven bad ones. At the bound the
# marker is kept, so the state stays visible and queryable, and the retry stops:
# the fix is a new build of that service, which the log names the command for.
#
# Set to 0 to retry for ever, which is the behaviour before #79.
CASCADE_MAX_ATTEMPTS=${CASCADE_MAX_ATTEMPTS:-3}

# The code a failure after a rollback exits with, which says which half failed.
#
# Read at the moment of the exit rather than decided in advance, because the
# same four call sites serve both halves of the run.
failure_exit_code() {
    if [ "$IN_CASCADE" = 1 ]; then echo "$CASCADE_EXIT_CODE"; else echo 1; fi
}

# Quote what the failing containers printed and what their own health endpoints
# answer, before rollback() replaces them.
#
# From #43, and the 2026-07-31 outage: nineteen deploys reported
# `not healthy after 180s: api(unhealthy)` and nothing else. That line reads as a
# health-check problem — a slow container, a flapping probe, too short a start
# period — and every one of those is a more plausible first guess than "a
# required environment variable is absent". The message that actually named
# `BAN_MARK_SALT` was inside the container, the rollback replaced the container,
# and the answer went with it. Twelve and a half hours.
#
# **This republishes container output into a public Actions log.** A process that
# prints a secret — an echoed connection string, a debug dump of its environment
# — has that secret copied here, permanently, into a place that cannot be
# unpublished. `scripts/env-drift.sh` avoids this by never printing a value at
# all; that option does not exist here, because the whole point is to quote what
# the container said. So the mitigation is bounded rather than absolute: only
# failing services, only on the failing path, capped in lines and in width. The
# probe body is the same risk surface and is bounded the same way. If a service
# ever needs to print or return something sensitive, it must not put it in logs
# or a health response.
report_failure_logs() {
    local svc container output probe_test probe_mode probe_url probe_output probe_rc
    local -a probe_parts probe_command

    log "--- what the failing containers printed and their probes answered (last ${HEALTH_LOG_LINES} lines each) ---"

    # **An empty section and a silent container are different findings** (#79).
    #
    # A capture with no service named prints the two markers and nothing between
    # them, which reads exactly like every container having said nothing — and
    # sends the reader to the images when the fault is in this script's own
    # bookkeeping. It cannot happen today: `$failing` and `$pending` are
    # appended in the same iteration, and the caller only runs when `$pending`
    # is non-empty. That is an invariant of two loops forty lines apart, which is
    # the kind that stops holding quietly.
    if [ "$#" -eq 0 ]; then
        log "no failing service was named, so nothing was captured."
        log "That is a fault in the deploy script rather than in any container — the health check decided something was wrong and did not say what."
        log "--- end of failing-container diagnostics ---"
        return
    fi
    for svc in "$@"; do
        container="kolonie-${svc}"

        # 2>&1 because a container that died on its first line wrote to stderr,
        # and `docker logs` reproduces the stream it was written on. Merging them
        # is the point. `|| true` because the container may already be gone, and
        # a missing log must not abort the deploy before rollback() runs.
        output=$(docker logs --tail "$HEALTH_LOG_LINES" "$container" 2>&1 || true)

        if [ -z "${output//[[:space:]]/}" ]; then
            # Said explicitly, because an empty section reads as a broken feature
            # and sends the reader looking for the log somewhere else. Nothing
            # printed is itself a finding: it means the process died before it
            # could speak, or never started.
            log "$svc: printed nothing — no output at all, on either stream."
            log "$svc: the failure is therefore before its first log line, not in what it reported."
        else
            printf '%s\n' "$output" | cut -c1-"$HEALTH_LOG_COLS" | sed "s/^/    [$svc] /"
        fi

        # Docker records the exact configured probe on the container. Ask the
        # same local HTTP endpoint once more, but preserve its body instead of
        # only its exit code: the badge-runner outage behind #106 answered 503
        # with `The loop is not running.` while its one log line said only that
        # it had started. Non-HTTP checks are replayed unchanged.
        #
        # This is deliberately best-effort. A missing health check, a stopped
        # container, an absent client or a timeout is diagnostic information and
        # must never prevent the rollback that follows.
        probe_test=$(docker inspect --format='{{range .Config.Healthcheck.Test}}{{println .}}{{end}}' "$container" 2>&1) || probe_test=""
        if [ -z "${probe_test//[[:space:]]/}" ]; then
            log "$svc probe: no configured health check could be read."
            continue
        fi

        mapfile -t probe_parts <<<"$probe_test"
        probe_mode="${probe_parts[0]}"
        probe_url=$(printf '%s\n' "${probe_parts[@]:1}" | grep -oE "https?://[^'\"\)[:space:]]+" | head -1 || true)
        probe_command=()

        if [ -n "$probe_url" ] && printf '%s\n' "${probe_parts[@]:1}" | grep -qx node; then
            probe_command=(node -e "fetch(process.argv[1],{signal:AbortSignal.timeout(${HEALTH_PROBE_TIMEOUT}000)}).then(async r=>{console.log(await r.text());process.exit(r.ok?0:1)}).catch(e=>{console.error(e.cause?.code||e.code||e.message);process.exit(1)})" "$probe_url")
        elif [ -n "$probe_url" ] && printf '%s\n' "${probe_parts[@]:1}" | grep -qx curl; then
            probe_command=(curl -sS --max-time "$HEALTH_PROBE_TIMEOUT" "$probe_url")
        elif [ -n "$probe_url" ] && printf '%s\n' "${probe_parts[@]:1}" | grep -qx wget; then
            probe_command=(wget -qO- -T "$HEALTH_PROBE_TIMEOUT" "$probe_url")
        elif [ "$probe_mode" = CMD ]; then
            probe_command=("${probe_parts[@]:1}")
        elif [ "$probe_mode" = CMD-SHELL ] && [ "${#probe_parts[@]}" -ge 2 ]; then
            probe_command=(/bin/sh -c "${probe_parts[1]}")
        else
            log "$svc probe: configured health check mode '$probe_mode' cannot be replayed."
            continue
        fi

        set +e
        # Bound before command substitution: limiting only the later print would
        # still make Bash retain an arbitrarily large response and could kill the
        # deploy before rollback. `--kill-after` makes the timeout hard even if
        # docker exec or the in-container client ignores TERM.
        probe_output=$(timeout --kill-after=1s "$HEALTH_PROBE_TIMEOUT" \
            docker exec "$container" "${probe_command[@]}" 2>&1 \
            | cut -c1-"$HEALTH_LOG_COLS" | tail -n "$HEALTH_LOG_LINES")
        probe_rc=$?
        set -e

        if [ -n "${probe_output//[[:space:]]/}" ]; then
            printf '%s\n' "$probe_output" | sed "s/^/    [$svc probe] /"
            if [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
                log "$svc probe: stopped after ${HEALTH_PROBE_TIMEOUT}s; the output above may be partial."
            fi
        elif [ "$probe_rc" -eq 0 ]; then
            log "$svc probe: answered with an empty body."
        elif [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
            log "$svc probe: did not answer within ${HEALTH_PROBE_TIMEOUT}s."
        else
            log "$svc probe: could not be asked (exit $probe_rc, no output)."
        fi
    done
    log "--- end of failing-container diagnostics ---"
}

healthcheck() {
    log "Waiting up to ${HEALTH_TIMEOUT}s for services to become healthy..."

    # Always check all profiled services, even on a single-service deploy.
    # If a migration broke another service, we must fail and roll back rather
    # than leaving the host silently diverged.
    services=$(cd "$DEPLOY_DIR" && docker compose "${PROFILE_ARGS[@]}" config --services)

    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local pending failing crashed status svc container restarts

    while :; do
        pending=""
        # The same set as $pending, as bare service names. $pending is a message
        # and carries its states in parentheses; report_failure_logs() needs
        # names it can build container names from.
        failing=""
        crashed=""
        for svc in $services; do
            container="kolonie-${svc}"
            # **`|| echo missing` does not do what it reads as, and #68 is where
            # that stopped being harmless.**
            #
            # A container with no health check at all makes this template fail:
            # `.State` has no `Health` key, and Docker answers with a parse error
            # on stderr — *after* having already written the rendered prefix, an
            # empty line, to stdout. Both streams are inside the command
            # substitution, so `|| echo missing` appends to the empty line rather
            # than replacing it and `$status` becomes a newline followed by
            # `missing`. No `case` arm matches that, so the service is read as
            # pending forever.
            #
            # It cost a rolled-back deploy on 2026-08-04: `kolonie-loki` ships
            # without a health check on purpose (its image is distroless and
            # holds no shell to run one with — docker-compose.yml says so at
            # length), the branch below was written for exactly that case, and it
            # was never reached. 180 seconds later the whole stack went back.
            #
            # `head -1` takes the rendered prefix and discards whatever follows;
            # empty then means what it always meant here — no health status to
            # read — and the branch below distinguishes "no health check" from
            # "no container" the way it always did, by asking whether it runs.
            # Deliberately not a cleverer template: `{{if .State.Health}}` is the
            # obvious fix and it fails the same way, because the missing key is
            # the error and testing for it is reading it.
            status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | head -1 || true)
            [ -n "$status" ] || status="missing"

            case "$status" in
                healthy) continue ;;
                missing)
                    # No health check defined, or the container is not there at
                    # all. Distinguish the two: the second is a real failure.
                    if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
                        continue
                    fi

                    # **A container that has never existed, for a service this
                    # deploy does not touch.** The guard above exists to catch a
                    # service this deploy *broke* — a migration dropping a column
                    # an older build reads. A service that has never been created
                    # cannot have been broken by anything, and asserting its health
                    # makes the first deploy after adding one fail on whichever
                    # service happens to go first.
                    #
                    # That is what happened on 2026-08-01: `support-triage-runner`
                    # entered the `full` profile, `deploy.sh api` created only the
                    # api, and the health check then waited 180s for a container
                    # nobody had asked it to create and rolled the deploy back. It
                    # is the same introduction problem as resolve_image's, one
                    # layer further on.
                    #
                    # Narrow deliberately: *never created*, and *not this deploy's
                    # service*. A container that existed and is gone still fails,
                    # because that is a service somebody removed.
                    if ! docker inspect "$container" >/dev/null 2>&1 \
                       && [ "$SERVICE" != all ] && [ "$SERVICE" != "$svc" ]; then
                        log "WARN: $svc has no container at all, and this deploy touches $SERVICE — not asserting its health"
                        continue
                    fi

                    pending="$pending $svc(not running)"
                    ;;
                *) pending="$pending $svc($status)" ;;
            esac

            failing="$failing $svc"

            # `{{.RestartCount}}`, not `{{.State.RestartCount}}` — the field is
            # top-level on the inspect document, and the plausible-looking one
            # under .State does not exist. Docker answers a template naming it
            # with a parse error on stderr and a non-zero exit, which this line
            # would have swallowed into `0` and never triggered on. Measured
            # against Docker 29.1.3 on 2026-07-31, along with the rest:
            # a container that throws on its first line under
            # `restart: unless-stopped` reports Status=restarting, Health=unhealthy,
            # **Running=true** and RestartCount climbing. Running is why the state
            # cannot carry this on its own.
            restarts=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo 0)
            # A non-numeric answer means the container is gone or the format was
            # not understood; neither is evidence of a crash loop, so it counts
            # as zero and the deadline stays in charge.
            case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

            if [ "$EARLY_FAIL_RESTARTS" -gt 0 ] && [ "$restarts" -ge "$EARLY_FAIL_RESTARTS" ]; then
                crashed="$crashed $svc(${restarts} restarts)"
            fi
        done

        [ -z "$pending" ] && break

        # Answered early, or at the deadline. Both paths quote the container
        # first: after rollback() the container is replaced and its log is gone.
        if [ -n "$crashed" ]; then
            log "ERROR: restarting in a loop and will not become healthy:$crashed"
            log "Not waiting out the remaining $(( deadline > SECONDS ? deadline - SECONDS : 0 ))s — a process that exits during startup exits just as fast on the next attempt."
            # shellcheck disable=SC2086  # deliberate word splitting: a service list
            report_failure_logs $failing
            rollback
            exit "$(failure_exit_code)"
        fi

        if [ "$SECONDS" -ge "$deadline" ]; then
            log "ERROR: not healthy after ${HEALTH_TIMEOUT}s:$pending"
            # shellcheck disable=SC2086  # deliberate word splitting: a service list
            report_failure_logs $failing
            rollback
            exit "$(failure_exit_code)"
        fi

        sleep 5
    done

    for svc in $services; do
        container="kolonie-${svc}"
        # Same shape as the read above, and the same fix: without `head -1` a
        # service with no health check is reported as a blank line followed by
        # the fallback. Cosmetic here — this loop only runs once everything has
        # already passed — but a summary line that renders as two is how somebody
        # concludes the deploy did something strange.
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | head -1 || true)
        [ -n "$status" ] || status="no health check"
        log "OK: $svc ($status)"
    done
}

# Rollback.
#
# **Never `--remove-orphans` here.** That flag deletes every container absent
# from the file it is given, and this file is a snapshot that may be incomplete
# or stale. On 2026-07-28 it was: `backup()` wrote it without the profile
# arguments, so it listed only traefik and postgres, and the rollback deleted
# api, verifier-runner and website — taking the whole site down in response to a
# single unhealthy container that was in fact serving every request. A rollback
# that destroys more than the deploy touched is not a safety net.
#
# It restores the last build that passed a health check, by digest, from
# `state/deployed.env`. That file is written only after a successful deploy, so
# while this deploy is in flight it still names the previous one — which is what
# makes returning to it a rollback rather than a retry. Until #12 this function
# could only restore the previous *configuration*, and since every image was
# `:latest`, `up -d` pulled the same bad build straight back.
#
# **With no recorded build, it does nothing at all.** That is the honest answer
# on a host that has not completed a deploy since this was introduced: there is
# no known-good version to return to, and tearing down containers that are
# serving in order to look decisive is how a safety net becomes the outage. The
# compose snapshot from backup() is kept for diagnosis and is deliberately not
# used here — it is a rendering of the configuration, not a record of a build,
# and it was the input that caused the harm described above.
#
# It cannot undo a migration. Since migrate() runs before deploy(), a health
# check that fails is a health check failing against a schema that has already
# moved. Whether returning to the previous build is safe then depends on whether
# the migration was additive — docs/disaster-recovery.md, Scenario 5, walks
# through both answers.
rollback() {
    log "Rolling back..."
    cd "$DEPLOY_DIR"

    if [ ! -f "$DEPLOYED_STATE" ]; then
        log "WARN: no previously deployed build recorded in $DEPLOYED_STATE."
        log "WARN: there is nothing known-good to return to, so nothing is being changed."
        log "WARN: whatever is running stays running. Investigate before deploying again."
        return
    fi

    # shellcheck disable=SC1090
    set -a; . "$DEPLOYED_STATE"; set +a

    log "Returning to the build deployed at ${DEPLOYED_AT:-unknown}:"
    log "  api:                   ${API_IMAGE:-unset}"
    log "  verifier-runner:       ${RUNNER_IMAGE:-unset}"
    log "  moderation-runner:     ${MODERATION_IMAGE:-unset}"
    log "  support-triage-runner: ${TRIAGE_IMAGE:-unset}"
    log "  badge-runner:          ${BADGE_IMAGE:-unset}"
    log "  website:               ${WEBSITE_IMAGE:-unset}"

    # No --remove-orphans, ever. That flag deletes every container absent from
    # the file it is given, and on 2026-07-28 it took api, verifier-runner and
    # website down in response to one unhealthy container that was in fact
    # serving every request. A rollback must never destroy more than the deploy
    # touched.
    if [ -n "${INFRA_COMMIT:-}" ]; then
        log "Returning /opt/kolonie to commit $INFRA_COMMIT..."
        git reset --hard "$INFRA_COMMIT"
    fi

    docker compose "${PROFILE_ARGS[@]}" up -d 2>&1 || {
        log "ERROR: Rollback also failed! Manual intervention needed."
        exit 2
    }
    log "Rollback completed — the previous build is serving again"

    # Record that this service was rolled back and needs re-deploying.
    #
    # The next successful deploy of a *different* service — typically the api,
    # which carries the migrations the runner was missing — will check this
    # marker and re-deploy the rolled-back service automatically. Without this,
    # a runner that deploys before the api fails, rolls back, and stays rolled
    # back after the api succeeds — which is the silent divergence #29 describes.
    #
    # The image tag is the one this deploy *tried* to ship, not the one it rolled
    # back to. The cascade needs to pull the same build the original deploy
    # intended. IMAGE_TAG variables are never modified by rollback(), so they
    # still hold the tag this deploy started with.
    local redeploy_tag
    case "$SERVICE" in
        api)               redeploy_tag="$API_IMAGE_TAG" ;;
        verifier-runner)   redeploy_tag="$RUNNER_IMAGE_TAG" ;;
        moderation-runner) redeploy_tag="$MODERATION_IMAGE_TAG" ;;
        support-triage-runner) redeploy_tag="$TRIAGE_IMAGE_TAG" ;;
        badge-runner)      redeploy_tag="$BADGE_IMAGE_TAG" ;;
        website)           redeploy_tag="$WEBSITE_IMAGE_TAG" ;;
        *)                 redeploy_tag="" ;;
    esac
    # How many times this exact image has now failed to re-deploy (#79).
    #
    # Counted per service *and* per tag: a new build of the same service is a
    # new question and starts at one, because what the bound is about is
    # retrying an image that has already answered. A rollback outside the
    # cascade is the first attempt by definition — nothing has been retried yet.
    local attempts=1
    if [ "$IN_CASCADE" = 1 ] && [ "${NEEDS_REDEPLOY_TAG:-}" = "$redeploy_tag" ]; then
        attempts=$((CASCADE_ATTEMPTS + 1))
    fi

    cat > "$STATE_DIR/needs-redeploy.env" <<REDEPLOY
NEEDS_REDEPLOY_SERVICE=$SERVICE
NEEDS_REDEPLOY_TAG=$redeploy_tag
NEEDS_REDEPLOY_ATTEMPTS=$attempts
REDEPLOY
    log "Recorded $SERVICE for cascade re-deploy in $STATE_DIR/needs-redeploy.env (attempt $attempts)"

    # **Say which half of this run failed, before the exit code is all that is
    # left** (#79). Inside the cascade, everything this run was *asked* to
    # deploy is already on the host and healthy; what failed is a retry of
    # somebody else's earlier rollback. A reader that cannot tell those apart
    # has to go and inspect the host to find out whether production moved.
    if [ "$IN_CASCADE" = 1 ]; then
        log "=== The deploy this run was asked for SUCCEEDED; the cascade did not ==="
        log "Deployed and healthy: ${ORIG_SERVICE:-unknown} at ${VERSION:-unknown} — migrations applied, deployed.env written."
        log "Failed: the cascade re-deploy of $SERVICE, which a previous run rolled back. It is not what this commit changed."
        log "Production is serving this run's build. The cascade is a separate fact and it is $attempts attempt(s) old."
    fi
}

# Main
log "=== Deployment started ==="
trap ghcr_logout EXIT

# Before any compose command, and the ordering is the whole point (#30).
#
# `docker-compose.yml` bind-mounts ./secrets into Traefik. **Docker creates a
# missing bind-mount source itself, as a root-owned directory** — so on a host
# that has never had one, the first `up -d` leaves /opt/kolonie/secrets owned by
# root, and the operator instruction in .env.example
#
#   htpasswd -nbB user pw >> /opt/kolonie/secrets/pgadmin.htpasswd
#
# then fails with "Permission denied" for the person following it exactly. That
# happened on the first real run of this. Creating it here means the deploy user
# owns it and the documented command works as documented.
#
# 700 rather than 755: it holds password hashes. Traefik reads it as root.
mkdir -p "${DEPLOY_DIR}/secrets" 2>/dev/null && chmod 700 "${DEPLOY_DIR}/secrets" 2>/dev/null || \
    log "WARN: could not prepare ${DEPLOY_DIR}/secrets — a basicAuth middleware reading from it will be dropped"

ghcr_login
detect_profile
# After detect_profile, so the snapshot includes the profiled services. Before
# pull, so it describes what is running now rather than what is about to.
backup
pull
# Immediately after the pull and before anything runs one of these images: every
# step below — the migration, the seed, the containers — must use the build this
# deploy inspected, not whatever `:latest` points at by the time it gets there.
pin
# After pin, so the labels are read off the exact builds this deploy will run,
# and before migrate — the first step that starts a container from one of them.
# A deploy refused here has moved nothing.
preflight_env
# Between the two on purpose: the images are on the host but nothing is serving
# from them yet, which is the only window in which the schema can be moved
# forward without a running API seeing a database it does not expect.
migrate
# After migrate, because the rows it writes need the columns migrate created.
# Before deploy, so the API never serves a task list it is about to change.
seed
deploy
healthcheck
# Only now. A build is known-good once it has answered, not once it has started,
# and this file is what the next failed deploy will roll back to.
record_deployment

# --- cascade re-deploy (#29) ------------------------------------------------
#
# If a prior deploy rolled back a service — typically because it built faster
# than the api and started against a schema one migration behind — and *this*
# deploy just succeeded (likely the api, carrying the migration), re-deploy the
# rolled-back service now that the database is current.
#
# This runs inline rather than re-invoking deploy.sh, because deploy.sh holds a
# flock and a second invocation would deadlock waiting for itself. The steps
# that are skipped (backup, migrate, seed) are either diagnostic or already done
# by the deploy that just succeeded.
#
# If the cascade itself fails, rollback() writes a new marker and the *next*
# successful deploy will try again. No infinite loop is possible because the
# marker is cleared before the attempt.
if [ -f "$STATE_DIR/needs-redeploy.env" ]; then
    # shellcheck disable=SC1090
    . "$STATE_DIR/needs-redeploy.env"

    if [ "${NEEDS_REDEPLOY_SERVICE:-}" != "$SERVICE" ] && [ -n "${NEEDS_REDEPLOY_SERVICE:-}" ]; then
        # A marker written before #79 carries no count; it has been tried at
        # least once by definition, so it reads as one rather than as zero.
        CASCADE_ATTEMPTS=${NEEDS_REDEPLOY_ATTEMPTS:-1}
        case "$CASCADE_ATTEMPTS" in ''|*[!0-9]*) CASCADE_ATTEMPTS=1 ;; esac

        # **The bound, and why it stops reddening the run** (#79).
        #
        # The marker pins a *tag*, not a service: `rollback()` re-writes it on
        # every failed retry, so no later commit is ever tried and a build that
        # is broken in itself reddens every deploy of every service until
        # somebody intervenes. Eleven consecutive runs on 2026-08-05 were that.
        #
        # At the bound the retry stops and the marker is kept — the state stays
        # visible in a file a maintainer can read, and this run reports the
        # truth, which is that what it was asked to deploy is deployed. The exit
        # is deliberately zero here: a standing condition somebody has to fix is
        # not a reason to fail an unrelated deploy for ever. It is loud instead.
        if [ "$CASCADE_MAX_ATTEMPTS" -gt 0 ] && [ "$CASCADE_ATTEMPTS" -ge "$CASCADE_MAX_ATTEMPTS" ]; then
            log "WARN: === Cascade re-deploy of $NEEDS_REDEPLOY_SERVICE is stuck, and is not being retried ==="
            log "WARN: it has failed $CASCADE_ATTEMPTS time(s) on the same image, ${NEEDS_REDEPLOY_TAG:-unknown} — the next attempt would pull the same build and fail the same way."
            log "WARN: this run's own deploy of $SERVICE succeeded and is serving; the stuck cascade is a separate fact and does not fail it."
            log "WARN: the fix is a new build of $NEEDS_REDEPLOY_SERVICE, deployed by naming it and a good commit:"
            log "WARN:   gh workflow run deploy.yml -R Kolonie-AI/kolonie-infra -f service=$NEEDS_REDEPLOY_SERVICE -f version=<a good full sha>"
            log "WARN: that path clears the marker at $STATE_DIR/needs-redeploy.env, which is kept rather than deleted so the condition stays queryable."
        else
            log "=== Cascade re-deploy: $NEEDS_REDEPLOY_SERVICE was rolled back by a prior deploy ==="
            log "Now that this deploy succeeded and migrations are current, re-deploying $NEEDS_REDEPLOY_SERVICE (attempt $((CASCADE_ATTEMPTS + 1)) of $CASCADE_MAX_ATTEMPTS)"

            # Clear BEFORE attempting, so a failure here does not cascade infinitely.
            rm -f "$STATE_DIR/needs-redeploy.env"
            IN_CASCADE=1

            # Restore the image tag the original deploy intended to ship.
            ORIG_SERVICE="$SERVICE"
            SERVICE="$NEEDS_REDEPLOY_SERVICE"
            case "$SERVICE" in
                api)               export API_IMAGE="$NEEDS_REDEPLOY_TAG"; API_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
                verifier-runner)   export RUNNER_IMAGE="$NEEDS_REDEPLOY_TAG"; RUNNER_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
                moderation-runner) export MODERATION_IMAGE="$NEEDS_REDEPLOY_TAG"; MODERATION_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
                support-triage-runner) export TRIAGE_IMAGE="$NEEDS_REDEPLOY_TAG"; TRIAGE_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
                badge-runner)      export BADGE_IMAGE="$NEEDS_REDEPLOY_TAG"; BADGE_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
                website)           export WEBSITE_IMAGE="$NEEDS_REDEPLOY_TAG"; WEBSITE_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
            esac

            detect_profile
            pull
            pin
            # migrate and seed are skipped: the deploy that triggered the cascade
            # already brought the schema and seed data current.
            deploy
            healthcheck
            record_deployment
            SERVICE="$ORIG_SERVICE"
            IN_CASCADE=0
            log "=== Cascade re-deploy of $NEEDS_REDEPLOY_SERVICE completed ==="
        fi
    else
        # The rolled-back service is the one we just deployed — our own deploy
        # succeeded, so the marker is stale.
        rm -f "$STATE_DIR/needs-redeploy.env"
    fi
fi

log "=== Deployment completed ==="
