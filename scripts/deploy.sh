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
WEBSITE_VERSION="${WEBSITE_VERSION:-}"

CUR_API=""
CUR_RUNNER=""
CUR_MOD=""
CUR_WEB=""
if [ -f "${STATE_DIR}/deployed.env" ]; then
    PREV_STATE=$(set -a; . "${STATE_DIR}/deployed.env"; set +a; echo "${API_IMAGE:-}|${RUNNER_IMAGE:-}|${MODERATION_IMAGE:-}|${WEBSITE_IMAGE:-}")
    CUR_API="${PREV_STATE%%|*}"
    CUR_RUNNER="$(echo "$PREV_STATE" | cut -d"|" -f2)"
    CUR_MOD="$(echo "$PREV_STATE" | cut -d"|" -f3)"
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

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${label}: no version given and none recorded in ${STATE_DIR}/deployed.env." >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${label}: pass a version, or deploy this service once so a build is recorded." >&2
    return 1
}

API_IMAGE_TAG=$(resolve_image "$API_VERSION" "$CUR_API" "$API_REPO" api)
RUNNER_IMAGE_TAG=$(resolve_image "$RUNNER_VERSION" "$CUR_RUNNER" "$RUNNER_REPO" verifier-runner)
MODERATION_IMAGE_TAG=$(resolve_image "$MODERATION_VERSION" "$CUR_MOD" "$MODERATION_REPO" moderation-runner)
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
# The application images are private and stay that way until the repositories go
# public at MVP (kolonie-docs#6). Public packages would publish the built source
# of kolonie-platform ahead of that decision — the images carry no secrets, but
# "no secrets" is the wrong test.
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
        log "WARN: api.kolonie.ai, academy.kolonie.ai, mcp.kolonie.ai and challenge.kolonie.ai will answer 502."
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
    WEBSITE_IMAGE=$(digest_of "$WEBSITE_IMAGE_TAG" "$WEBSITE_REPO")
    export API_IMAGE RUNNER_IMAGE MODERATION_IMAGE WEBSITE_IMAGE

    log "  api:               $API_IMAGE"
    log "  verifier-runner:   $RUNNER_IMAGE"
    log "  moderation-runner: $MODERATION_IMAGE"
    log "  website:           $WEBSITE_IMAGE"
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
    local recorded_moderation="${MODERATION_IMAGE}" recorded_website="${WEBSITE_IMAGE}"

    if [ "$SERVICE" != all ] && [ -f "$DEPLOYED_STATE" ]; then
        # Read the previous record in a subshell, so sourcing it cannot clobber
        # the variables this deploy just resolved.
        local previous
        previous=$(set -a; . "$DEPLOYED_STATE"; set +a; echo "${API_IMAGE}|${RUNNER_IMAGE}|${MODERATION_IMAGE}|${WEBSITE_IMAGE}")
        [ "$SERVICE" != api ]               && recorded_api="${previous%%|*}"
        [ "$SERVICE" != verifier-runner ]   && recorded_runner="$(cut -d'|' -f2 <<<"$previous")"
        [ "$SERVICE" != moderation-runner ] && recorded_moderation="$(cut -d'|' -f3 <<<"$previous")"
        [ "$SERVICE" != website ]           && recorded_website="${previous##*|}"
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
                    "MODERATION_IMAGE=${recorded_moderation}" "WEBSITE_IMAGE=${recorded_website}"; do
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
    log "Migrations: done"
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
            exit 1
        }
    else
    if [ -n "${INFRA_COMMIT:-}" ]; then
        log "Returning /opt/kolonie to commit $INFRA_COMMIT..."
        git reset --hard "$INFRA_COMMIT"
    fi

        docker compose "${PROFILE_ARGS[@]}" up -d "${orphan_args[@]+"${orphan_args[@]}"}" "$SERVICE" 2>&1 || {
            log "ERROR: Deployment failed"
            rollback
            exit 1
        }
    fi
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

healthcheck() {
    log "Waiting up to ${HEALTH_TIMEOUT}s for services to become healthy..."

    # Always check all profiled services, even on a single-service deploy.
    # If a migration broke another service, we must fail and roll back rather
    # than leaving the host silently diverged.
    services=$(cd "$DEPLOY_DIR" && docker compose "${PROFILE_ARGS[@]}" config --services)

    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local pending status svc container

    while :; do
        pending=""
        for svc in $services; do
            container="kolonie-${svc}"
            status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")

            case "$status" in
                healthy) ;;
                missing)
                    # No health check defined, or the container is not there at
                    # all. Distinguish the two: the second is a real failure.
                    if docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
                        :
                    else
                        pending="$pending $svc(not running)"
                    fi
                    ;;
                *) pending="$pending $svc($status)" ;;
            esac
        done

        [ -z "$pending" ] && break

        if [ "$SECONDS" -ge "$deadline" ]; then
            log "ERROR: not healthy after ${HEALTH_TIMEOUT}s:$pending"
            rollback
            exit 1
        fi

        sleep 5
    done

    for svc in $services; do
        container="kolonie-${svc}"
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no health check")
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
    log "  api:               ${API_IMAGE:-unset}"
    log "  verifier-runner:   ${RUNNER_IMAGE:-unset}"
    log "  moderation-runner: ${MODERATION_IMAGE:-unset}"
    log "  website:           ${WEBSITE_IMAGE:-unset}"

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
        website)           redeploy_tag="$WEBSITE_IMAGE_TAG" ;;
        *)                 redeploy_tag="" ;;
    esac
    cat > "$STATE_DIR/needs-redeploy.env" <<REDEPLOY
NEEDS_REDEPLOY_SERVICE=$SERVICE
NEEDS_REDEPLOY_TAG=$redeploy_tag
REDEPLOY
    log "Recorded $SERVICE for cascade re-deploy in $STATE_DIR/needs-redeploy.env"
}

# Main
log "=== Deployment started ==="
trap ghcr_logout EXIT
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
        log "=== Cascade re-deploy: $NEEDS_REDEPLOY_SERVICE was rolled back by a prior deploy ==="
        log "Now that this deploy succeeded and migrations are current, re-deploying $NEEDS_REDEPLOY_SERVICE"

        # Clear BEFORE attempting, so a failure here does not cascade infinitely.
        rm -f "$STATE_DIR/needs-redeploy.env"

        # Restore the image tag the original deploy intended to ship.
        ORIG_SERVICE="$SERVICE"
        SERVICE="$NEEDS_REDEPLOY_SERVICE"
        case "$SERVICE" in
            api)               export API_IMAGE="$NEEDS_REDEPLOY_TAG"; API_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
            verifier-runner)   export RUNNER_IMAGE="$NEEDS_REDEPLOY_TAG"; RUNNER_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
            moderation-runner) export MODERATION_IMAGE="$NEEDS_REDEPLOY_TAG"; MODERATION_IMAGE_TAG="$NEEDS_REDEPLOY_TAG" ;;
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
        log "=== Cascade re-deploy of $NEEDS_REDEPLOY_SERVICE completed ==="
    else
        # The rolled-back service is the one we just deployed — our own deploy
        # succeeded, so the marker is stale.
        rm -f "$STATE_DIR/needs-redeploy.env"
    fi
fi

log "=== Deployment completed ==="
