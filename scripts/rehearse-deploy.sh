#!/bin/bash
# Rehearse deploy.sh without a VPS, containers, or a registry.
#
# Usage: ./scripts/rehearse-deploy.sh
#
# `deploy.sh` is the most dangerous script in this repository — it is the one
# that can take the Colony offline — and until 2026-07-28 nothing exercised it
# anywhere but production. The two failures that hurt most were both discovered
# by being deployed: a rollback that deleted three services it had not created,
# and a deploy step calling a script the image did not have.
#
# So: run the real script with a stub `docker` on PATH and a scratch directory
# in place of /opt/kolonie, and assert on what it *would have done*. This is not
# a substitute for a real deploy — it proves the logic, never the environment —
# but it makes the failure modes above cheap to check before they are expensive
# to discover. Writing it immediately paid for itself: it found `digest_of`
# logging to stdout, which put a warning line inside an image reference.
#
# Add a case here for every branch of deploy.sh that decides whether containers
# live or die.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$BIN"
cp "$ROOT/docker-compose.yml" "$WORK/"
cp -r "$ROOT/scripts" "$WORK/"

# --- the stub -------------------------------------------------------------
# Records every invocation, and answers the handful of questions deploy.sh asks.
# The failure switches (FAIL_UP, FAIL_SEED, FAIL_DIGEST, UNHEALTHY) are how a
# case chooses which branch of the script it is testing.
cat > "$BIN/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$DOCKER_LOG"

case "$1 ${2:-}" in
  "pull"*)
      # How detect_profile() probes reachability. It used `docker manifest
      # inspect` until f624063 and this stub answered that instead — so from
      # then until #38 the probe fell through to the catch-all `exit 0`, the
      # UNREACHABLE switch reached nothing, and three cases asserted on a
      # command the deploy no longer ran. The deploy itself was fine the whole
      # time; only its rehearsal had stopped watching.
      #
      # Every image reachable, unless a case names one that is not. UNREACHABLE
      # holds a repository, and the tag is the last argument.
      for tag in "$@"; do :; done
      [ "${UNREACHABLE:-}" = "${tag%%:*}" ] && exit 1
      exit 0 ;;
  "image inspect")
      # Two questions come through here. preflight_env() asks for the label an
      # image declares its required environment in (#42); everything else is
      # digest_of asking for RepoDigests.
      if echo "$*" | grep -qF 'ai.kolonie.required-env'; then
        # DECLARING_IMAGE is a repository substring, DECLARED_VARS what that
        # image declares. Every other image answers with an empty line and
        # exit 0 — measured against Docker 29.1.3, for an image with no labels
        # and for an image carrying other labels but not this one. That is what
        # every image built before kolonie-platform#75 answers.
        for ref in "$@"; do :; done
        if [ -n "${DECLARING_IMAGE:-}" ] && [[ "$ref" == *"$DECLARING_IMAGE"* ]]; then
          echo "${DECLARED_VARS:-}"
        else
          echo ""
        fi
        exit 0
      fi
      # the tag is the last argument; return the digest for its own repo, plus a
      # decoy from another repo to prove the prefix match is doing work.
      for tag in "$@"; do :; done
      repo="${tag%%:*}"
      # A digest reference is `repo@sha256:<hex>`, so cutting at the first colon
      # leaves `repo@sha256` — and the RepoDigests line built from it would carry
      # `@sha256` twice, which real Docker never answers and `digest_of`'s
      # `^${repo}@` match would never find. Strip it, so an image resolved from a
      # recorded digest is answered the way the daemon answers it.
      repo="${repo%@sha256}"
      if [ "${FAIL_DIGEST:-}" = "$repo" ]; then exit 1; fi
      # The workplace answers the digest #243 pinned, so a case can assert that
      # the reviewed build is what the deploy resolved rather than only that some
      # digest came back.
      if [ "$repo" = ghcr.io/kolonie-ai/kolonie-workplace ]; then
        echo "${repo}@sha256:4a8a98f485bfbeab84bdb3c5192780661331935131c23881698b853ef80bc794"
        exit 0
      fi
      echo "ghcr.io/someone-else/other@sha256:$(printf %064d 0)"
      echo "${repo}@sha256:$(echo -n "$repo" | sha256sum | cut -c1-64)"
      exit 0 ;;
  "compose"*)
      # Kept before the flags are shifted away: the `config --services` handler
      # below has to know which profiles were asked for, and by then they are
      # gone.
      RAW_ARGS="$*"
      # find the compose subcommand after the flags
      shift
      sub=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --profile) shift 2; continue ;;
          -f) shift 2; continue ;;
          -*) shift; continue ;;
          *) sub="$1"; break ;;
        esac
      done
      case "$sub" in
        # Records what compose was *told* to fetch. deploy.sh exports
        # API_IMAGE before the pull and overwrites it with a digest after, so
        # this is the only place the requested version is observable.
        pull)    echo "compose pull API_IMAGE=${API_IMAGE:-unset}" >> "$DOCKER_LOG" ;;
        config)
          if echo "$*" | grep -q -- "--services"; then
            echo -e "api\nverifier-runner\nsupport-triage-runner\nbadge-runner\ndoctor-runner\nwebsite"
            # The infrastructure services are off by default rather than always
            # listed, because healthcheck() iterates whatever this answers and
            # every existing case above asserts against the five application
            # services. A case that needs one names it (#84).
            for extra in ${EXTRA_SERVICES:-}; do echo "$extra"; done
            # pgadmin only when its profile is on, because that is the whole
            # property #30's placement turns on: a service inside the active
            # profiles is one healthcheck() will roll the stack back for.
            case "$RAW_ARGS" in *"--profile workplace"*) echo "workplace" ;; esac
            case "$RAW_ARGS" in *"--profile admin"*) echo "pgadmin" ;; esac
          else
            echo "services: {}"
          fi
          ;;
        ps)      echo "[]" ;;
        run)     [ "${FAIL_SEED:-}" = 1 ] && { echo "Missing script: seed" >&2; exit 1; } ; exit 0 ;;
        up)      # fail only the first `up`, so the rollback's own `up` can succeed
                 if [ "${FAIL_UP:-}" = 1 ] && [ ! -f "$DOCKER_LOG.upfailed" ]; then
                   touch "$DOCKER_LOG.upfailed"; exit 1
                 fi
                 # FAIL_UP_NTH fails one specific `up` by ordinal, which is the
                 # only way to reach the cascade's own deploy: the run's first
                 # `up` is the deploy this run was asked for and has to succeed,
                 # or the cascade is never reached at all (#79).
                 if [ -n "${FAIL_UP_NTH:-}" ]; then
                   ups=$(( $(cat "$DOCKER_LOG.upcount" 2>/dev/null || echo 0) + 1 ))
                   echo "$ups" > "$DOCKER_LOG.upcount"
                   [ "$ups" = "$FAIL_UP_NTH" ] && exit 1
                 fi
                 exit 0 ;;
      esac
      exit 0 ;;
  "inspect"*)
      # healthcheck() asks three different questions through `docker inspect`,
      # so the stub tells them apart by the --format it was handed.
      #
      # **Matched exactly, and an unknown format is a failure rather than a
      # default.** A stub that answers a template Docker would reject is worse
      # than no stub: it makes the rehearsal agree with a deploy that cannot
      # work. This was not hypothetical — the first version of the crash-loop
      # check asked for `{{.State.RestartCount}}`, which does not exist (the
      # field is top-level), and a stub matching on the substring `RestartCount`
      # answered it happily. Real Docker answers it with a parse error. Keep
      # this list in step with `grep 'docker inspect' scripts/deploy.sh`.
      # A container that has never existed fails *every* inspect, whatever the
      # format — docker exits non-zero with "No such object". Answering the
      # health format for it would report `unhealthy`, which is a different
      # condition and the one the branch under test is not about.
      for container in "$@"; do :; done
      [ "${ABSENT_CONTAINER:-}" = "$container" ] && exit 1

      # `docker inspect <name>` with no --format is deploy.sh asking whether the
      # container exists at all — a different question from the three below, and
      # the one that tells a service being introduced apart from one that broke.
      if ! echo "$*" | grep -q -- "--format"; then exit 0; fi

      case "$*" in
        *"{{.State.Health.Status}}"*|*"{{.State.Running}}"*|*"{{.RestartCount}}"*) ;;
        *"{{range .Config.Healthcheck.Test}}"*) ;;
        *"{{.State.StartedAt}}"*|*"{{range .Mounts}}"*) ;;
        *) echo "STUB: unknown docker inspect format: $*" >&2; exit 125 ;;
      esac

      if echo "$*" | grep -qF '{{range .Config.Healthcheck.Test}}'; then
        if [ "${NO_PROBE_FOR:-}" = "$container" ]; then exit 1; fi
        printf '%s\n' CMD node -e "fetch('http://127.0.0.1:3004/health')"
        exit 0
      fi

      # What recreate_stale_mounted_config() asks, and it asks two things (#84).
      #
      # MOUNTS_FOR names the one container that reports a bind mount, and
      # MOUNTS_LIST holds its `source|destination` pairs. Every other container
      # answers with nothing, which is what a container with only named volumes
      # answers and is the case the function must not act on.
      if echo "$*" | grep -qF '{{range .Mounts}}'; then
        if [ -n "${MOUNTS_FOR:-}" ] && [ "$MOUNTS_FOR" = "$container" ]; then
          printf '%s\n' ${MOUNTS_LIST:-}
        fi
        exit 0
      fi
      # STARTED_AT is when every container started. A case sets it either side of
      # the config file's mtime, which is the whole of what the function decides
      # on — the file is newer than the process that read it, or it is not.
      if echo "$*" | grep -qF '{{.State.StartedAt}}'; then
        echo "${STARTED_AT:-2026-01-01T00:00:00Z}"
        exit 0
      fi

      if echo "$*" | grep -qF '{{.RestartCount}}'; then
        # CRASHLOOP_SERVICE names a container Docker keeps restarting — the
        # shape of a process that throws on its first line under
        # `restart: unless-stopped`, which is what the 2026-07-31 outage was.
        if [ -n "${CRASHLOOP_SERVICE:-}" ] && echo "$*" | grep -q "${CRASHLOOP_SERVICE}"; then
          echo "${CRASHLOOP_COUNT:-5}"
        else
          echo 0
        fi
        exit 0
      fi
      if echo "$*" | grep -qF '{{.State.Running}}'; then echo true; exit 0; fi

      # A container that has **no health check at all**, which is what
      # `kolonie-loki` is (#68). This is not "unknown state" and not "absent" —
      # it is a running container whose `.State` has no `Health` key, and Docker
      # answers it in a way no other case here does: it writes the rendered
      # prefix to stdout — an empty line — and *then* fails with a parse error on
      # stderr.
      #
      # Both halves are reproduced deliberately. The empty line is the whole
      # defect: it is what turned `|| echo missing` in deploy.sh into a status of
      # newline-plus-missing, matching no `case` arm, and rolled a deploy back
      # 180 seconds later on 2026-08-04. A stub that only exited 1 would let the
      # broken version pass.
      if [ -n "${NO_HEALTHCHECK_SERVICE:-}" ] && echo "$*" | grep -q "${NO_HEALTHCHECK_SERVICE}"; then
        echo ""
        echo 'template parsing error: template: :1:9: executing "" at <.State.Health.Status>: map has no entry for key "Health"' >&2
        exit 1
      fi

      if [ "${UNHEALTHY:-}" = 1 ]; then echo "unhealthy"
      elif [ -n "${UNHEALTHY_SERVICE:-}" ] && echo "$*" | grep -q "${UNHEALTHY_SERVICE}"; then echo "unhealthy"
      else echo "healthy"
      fi
      exit 0 ;;
  "logs"*)
      # What the container printed, which #43 quotes before the rollback
      # replaces it. LOG_FOR names the one container with output; every other
      # container is silent, which is the case the "printed nothing" branch of
      # report_failure_logs() exists for.
      for container in "$@"; do :; done
      if [ "${LOG_FOR:-}" = "$container" ]; then printf '%s\n' "${LOG_TEXT:-}"; fi
      exit 0 ;;
  "exec"*)
      container="${2:-}"
      if [ "${PROBE_TIMEOUT_FOR:-}" = "$container" ]; then
        [ -n "${PROBE_PARTIAL:-}" ] && printf '%s\n' "$PROBE_PARTIAL"
        exec sleep 10
      fi
      if [ "${PROBE_UNREACHABLE_FOR:-}" = "$container" ]; then
        echo "container is not running" >&2
        exit 1
      fi
      if [ -z "${PROBE_BODY_FOR:-}" ] || [ "$PROBE_BODY_FOR" = "$container" ]; then
        printf '%s\n' "${PROBE_BODY:-{\"status\":\"ok\"}}"
      fi
      [ "${PROBE_FAIL_FOR:-}" = "$container" ] && exit 1
      exit 0 ;;
  "login"*|"logout"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

run_deploy() {
  local av="${API_VERSION:-some-sha}" rv="${RUNNER_VERSION:-some-sha}" mv="${MODERATION_VERSION:-some-sha}" tv="${TRIAGE_VERSION:-some-sha}" bv="${BADGE_VERSION:-some-sha}" dv="${DOCTOR_VERSION:-some-sha}" wv="${WEBSITE_VERSION:-some-sha}" wpv="${WORKPLACE_VERSION:-some-sha}"
  if [ "${NO_VERSIONS:-}" = "1" ]; then av=""; rv=""; mv=""; tv=""; bv=""; dv=""; wv=""; wpv=""; fi
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" TRIAGE_VERSION="$tv" BADGE_VERSION="$bv" DOCTOR_VERSION="$dv" WEBSITE_VERSION="$wv" WORKPLACE_VERSION="$wpv" \
  DOCKER_LOG="$WORK/docker.log" \
  PATH="$BIN:$PATH" DEPLOY_DIR="$WORK" GHCR_TOKEN=x HEALTH_TIMEOUT=5 \
  "$@" bash "$WORK/scripts/deploy.sh" all 2>&1
}

# Same, for a deploy of one named service — which is what a build in
# kolonie-platform triggers.
run_deploy_service() {
  local av="${API_VERSION:-some-sha}" rv="${RUNNER_VERSION:-some-sha}" mv="${MODERATION_VERSION:-some-sha}" tv="${TRIAGE_VERSION:-some-sha}" bv="${BADGE_VERSION:-some-sha}" dv="${DOCTOR_VERSION:-some-sha}" wv="${WEBSITE_VERSION:-some-sha}" wpv="${WORKPLACE_VERSION:-some-sha}"
  local service="$1"; shift
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" TRIAGE_VERSION="$tv" BADGE_VERSION="$bv" DOCTOR_VERSION="$dv" WEBSITE_VERSION="$wv" WORKPLACE_VERSION="$wpv" \
  DOCKER_LOG="$WORK/docker.log" \
  PATH="$BIN:$PATH" DEPLOY_DIR="$WORK" GHCR_TOKEN=x HEALTH_TIMEOUT=5 \
  "$@" bash "$WORK/scripts/deploy.sh" "$service" 2>&1
}

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent() { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

echo "== 1. a healthy deploy pins by digest and records it"
: > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "Pinning images to the digests just pulled" "pin() ran"
contains "$out" "ghcr.io/kolonie-ai/kolonie-api@sha256:" "api pinned to a digest"
contains "$out" "Recorded the deployed build" "deployment recorded"
check "state file written" "$([ -f "$WORK/state/deployed.env" ] && echo yes || echo no)" "yes"
contains "$(cat "$WORK/state/deployed.env")" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:" "state file holds the digest"
# the containers must have been started with the digest exported
contains "$(cat "$WORK/docker.log")" "compose --profile full --profile website --profile workplace up -d --remove-orphans" "up -d ran"

echo "== 2. the migrate and seed containers run the pinned build, not :latest"
grep -q 'compose .*run --rm -T api npm run migrate' "$WORK/docker.log" && echo "  ok   migrate ran" && pass=$((pass+1))
recorded_api=$(grep '^API_IMAGE=' "$WORK/state/deployed.env" | cut -d= -f2-)
check "pinned ref is a digest, not a tag" "$(grep -c '@sha256:' <<<"$recorded_api")" "1"

echo "== 3. rollback with no recorded build changes nothing"
rm -rf "$WORK/state"
: > "$WORK/docker.log"
rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env FAIL_UP=1)
contains "$out" "no previously deployed build recorded" "said why it did nothing"
contains "$out" "whatever is running stays running" "left the host alone"
absent "$(grep 'compose' "$WORK/docker.log" | grep 'up -d' | tail -n +2)" "up -d" "no second up -d after the failure"

echo "== 4. rollback with a recorded build returns to it"
# seed a known-good record, then fail the deploy
mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env FAIL_UP=1)
contains "$out" "Returning to the build deployed at 19990101_000000" "named the build it returned to"
contains "$out" "kolonie-api@sha256:$(printf %064d 1)" "returned to the recorded digest"
contains "$out" "Rollback completed" "rollback completed"
absent "$(grep 'up -d' "$WORK/docker.log" | tail -n1)" "--remove-orphans" "rollback did not pass --remove-orphans"
# the failed build must not have overwritten the known-good record
contains "$(cat "$WORK/state/deployed.env")" "DEPLOYED_AT=19990101_000000" "a failed deploy did not overwrite the record"

echo "== 5. an unresolvable digest degrades to the tag rather than aborting"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env FAIL_DIGEST=ghcr.io/kolonie-ai/kolonie-website)
contains "$out" "no digest recorded for ghcr.io/kolonie-ai/kolonie-website:some-sha" "warned about the unpinnable image"
contains "$out" "Deployment completed" "deploy still finished"
contains "$(cat "$WORK/state/deployed.env")" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website:some-sha" "recorded the tag it actually used"

echo "== 6. a caller that names a version gets that build, not :latest"
# The point of #14: a deploy triggered by a build in kolonie-platform ships the
# commit that triggered it. Without this, the deploy probes and pulls whatever
# is sitting in :latest, which need not be the build that asked for the deploy.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
SHA=$(printf %040d 7)
out=$(run_deploy env API_VERSION="$SHA")
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-api:$SHA" "probed the requested version"
contains "$(cat "$WORK/docker.log")" "compose pull API_IMAGE=ghcr.io/kolonie-ai/kolonie-api:$SHA" "pulled the requested version"
contains "$out" "Deployment completed" "deploy finished"
# And the other two images are untouched by an api-only version.
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-website:some-sha" "website stayed on latest"

echo "== 7. a deploy that can name no build at all is refused"
# Nothing passed and nothing recorded. The old message said the deploy had
# "defaulted to latest", which was the reason this guard was written but not what
# had happened: nothing defaulted to anything, there was simply no build to name.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env || true)
contains "$out" "no version given and none recorded" "said what was actually missing"
contains "$out" "api:" "and which image it was missing for"

echo "== 7b. an explicit `latest` is still refused"
# The guard PR #41 was written for. A caller may not ask for the mutable tag:
# it ships whatever finished building most recently, which need not be the commit
# that asked for the deploy.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env API_VERSION=latest || true)
contains "$out" "the deploy names the image it intends, not :latest." "refused an explicit latest"

echo "== 7c. an absent version falls back to the recorded digest, whole"
# The regression this replaces: `${recorded#*:}` strips up to the first colon,
# which in `repo@sha256:<hex>` is the one inside `sha256:` — so the fallback
# produced `repo:<hex>`, a tag that has never existed. Every image the deploy was
# not explicitly given then probed as unreachable.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
DIGEST="ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 9)"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=$DIGEST
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 2)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env)
# detect_profile probes the api and the website — the two that decide which
# compose profiles come up — so the api digest is where the reference is
# observable before pin() replaces everything with digests anyway.
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "probed the recorded digest itself"
absent "$(cat "$WORK/docker.log")" "kolonie-api:0000" "and never rebuilt it into a tag"
absent "$(cat "$WORK/docker.log")" "kolonie-verifier-runner:0000" "same for an image it does not probe"
contains "$out" "Deployment completed" "the deploy ran on recorded digests alone"

echo "== 7d. a digest that lost its '@' is read back as a digest"
# The repair path for the records written while the split was live. This ran in
# production: deployed.env held ghcr.io/kolonie-ai/kolonie-website:cf52b9a8… —
# 64 hex characters, which is a sha256 without its separator and not a tag anyone
# pushed. Without this the next website rollback resolves nothing.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
HEX=$(printf %064d 5)
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api:${HEX}
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env)
contains "$out" "which is a digest that lost its '@' — reading it as one" "said what it was repairing"
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-api@sha256:${HEX}" "probed it as a digest"

echo "== 7e. a real tag is left alone"
# The heuristic must not eat a 40-character git SHA, which is what every tag in
# this project actually is.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
GITSHA=$(printf %040d 6)
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api:${GITSHA}
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env)
absent "$out" "digest that lost its '@'" "left a git-sha tag alone"
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-api:${GITSHA}" "and probed it as the tag it is"

echo "== 8. a single-service deploy never passes --remove-orphans"
# A deploy of one service has no business asserting what the whole host should
# contain, and that flag deletes everything the compose view does not list.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy_service api env API_VERSION="$SHA")
contains "$out" "Not passing --remove-orphans" "said why it withheld the flag"
absent "$(grep 'up -d' "$WORK/docker.log")" "--remove-orphans" "no --remove-orphans on a service deploy"
contains "$(grep 'up -d' "$WORK/docker.log")" "up -d api" "still deployed the named service"

echo "== 9. an unreachable image withholds --remove-orphans on a full deploy"
# The deploy runs under the token of whichever repository triggered it, and that
# token need not be able to read every package. A website container the pull
# could not see is not an orphan — it is a running service, and removing it is
# the 2026-07-28 outage again.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env UNREACHABLE=ghcr.io/kolonie-ai/kolonie-website)
contains "$out" "compose view is incomplete" "named the reason"
absent "$(grep 'up -d' "$WORK/docker.log")" "--remove-orphans" "no --remove-orphans with a missing image"
contains "$out" "Deployment completed" "the rest of the deploy still ran"

echo "== 10. a complete full deploy still passes --remove-orphans"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$(grep 'up -d' "$WORK/docker.log")" "--remove-orphans" "flag kept where the view is authoritative"

echo "== 11. a single-service deploy does not rewrite the other services' digests"
# The bug this guards: since #14 a deploy can name one service, and the other two
# are never pulled — so pin() resolves their digests from stale local tags. If
# those were recorded, rollback() would return to a build that never served.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
: > "$WORK/docker.log"
out=$(run_deploy_service verifier-runner env RUNNER_VERSION="$SHA")
recorded=$(cat "$WORK/state/deployed.env")
contains "$recorded" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "api digest carried over untouched"
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
contains "$recorded" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)" "website digest carried over untouched"
absent "$recorded" "RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)" "runner digest was replaced"
contains "$recorded" "RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:" "runner digest is a digest"

echo "== 12. a full deploy still records all three"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
recorded=$(cat "$WORK/state/deployed.env")
for img in kolonie-api kolonie-verifier-runner kolonie-website; do
  contains "$recorded" "ghcr.io/kolonie-ai/${img}@sha256:" "$img recorded"
done

echo "== 13. a runner deploy that rolls back records itself for cascade re-deploy"
# The runner builds faster, deploys first, fails (schema is behind), and rolls
# back. It must leave a marker so the next successful deploy can re-deploy it.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
# Seed a known-good record so rollback() has something to return to.
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service verifier-runner env RUNNER_VERSION="$SHA" FAIL_UP=1)
contains "$out" "Rollback completed" "runner rolled back"
contains "$out" "Recorded verifier-runner for cascade re-deploy" "marker written"
check "needs-redeploy.env exists" "$([ -f "$WORK/state/needs-redeploy.env" ] && echo yes || echo no)" "yes"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_SERVICE=verifier-runner" "marker names the right service"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-verifier-runner:$SHA" "marker carries the intended tag"

echo "== 14. a subsequent api deploy cascade re-deploys the rolled-back runner"
# The api deploy succeeds (migrates, etc.), then reads the marker and re-deploys
# the runner. This is the core fix for #29: the runner that failed against old
# schema gets a second chance now that the schema is current.
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env)
contains "$out" "Cascade re-deploy: verifier-runner was rolled back" "cascade triggered"
contains "$out" "Cascade re-deploy of verifier-runner completed" "cascade succeeded"
check "marker cleaned up" "$([ -f "$WORK/state/needs-redeploy.env" ] && echo yes || echo no)" "no"
# The runner must have been pulled and started during the cascade.
contains "$(cat "$WORK/docker.log")" "compose --profile full --profile website --profile workplace pull verifier-runner" "cascade pulled the runner"

echo "== 15. a single-service deploy asserts the health of all profiled services"
# This prevents silent divergence in the reverse direction: if a migration
# breaks an existing service (e.g., dropping a column the old build reads),
# the deploy must fail and roll back rather than succeeding on its own.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy_service verifier-runner env RUNNER_VERSION="$SHA" UNHEALTHY_SERVICE=kolonie-api || true)
contains "$out" "ERROR: not healthy after 5s" "failed because another service was unhealthy"
contains "$out" "api(unhealthy)" "named the service that failed"

echo "== 16. a cascade re-deploy that itself fails writes a new marker"
# No infinite loop: the marker is cleared before the cascade attempt, and if the
# cascade's deploy() fails and rollback() runs, it writes a fresh marker. The
# next successful deploy will try again.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
# First: runner deploys, fails, writes marker
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
run_deploy_service verifier-runner env RUNNER_VERSION="$SHA" FAIL_UP=1 > /dev/null 2>&1
check "marker exists after runner rollback" "$([ -f "$WORK/state/needs-redeploy.env" ] && echo yes || echo no)" "yes"
# Now: api deploys successfully, but the cascade's up will fail.
# We use FAIL_UP=1 again — the main api deploy's up succeeds (consuming the
# first failure), and the cascade's up for the runner fails (the second up).
# But FAIL_UP only fails the FIRST up, so this won't work directly.
# Instead, write a marker and verify it was read:
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env || true)
contains "$out" "Cascade re-deploy: verifier-runner was rolled back" "cascade was attempted"

echo "== 16b. a failure inside the cascade says which half of the run failed (#79)"
# The defect: a deploy that failed only in its cascade reported the same red as
# one that never reached the host. Eleven consecutive runs on 2026-08-05 were
# successful deploys of everything that had changed, all of them red.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:3333333333333333333333333333333333333333333333333333333333333333
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 3)
EOF
cat > "$WORK/state/needs-redeploy.env" <<EOF
NEEDS_REDEPLOY_SERVICE=badge-runner
NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-badge-runner:$SHA
NEEDS_REDEPLOY_ATTEMPTS=1
EOF
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
# The run's own `up` is the first; the cascade's is the second.
out=$(run_deploy_service api env API_VERSION="$SHA" FAIL_UP_NTH=2 || true)
rc=$?
contains "$out" "Cascade re-deploy: badge-runner was rolled back" "the cascade was attempted"
contains "$out" "The deploy this run was asked for SUCCEEDED; the cascade did not" "the two halves are told apart"
contains "$out" "Production is serving this run's build" "the reader is told whether production moved"

echo "== 16c. and it exits with a code that says so"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
cat > "$WORK/state/needs-redeploy.env" <<EOF
NEEDS_REDEPLOY_SERVICE=badge-runner
NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-badge-runner:$SHA
NEEDS_REDEPLOY_ATTEMPTS=1
EOF
run_deploy_service api env API_VERSION="$SHA" FAIL_UP_NTH=2 > /dev/null 2>&1
check "a cascade failure exits 3, not 1" "$?" "3"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_ATTEMPTS=2" "the attempt was counted"

echo "== 16d. repeated failures reach the bound and stop reddening unrelated deploys (#105)"
# The marker pins a tag, so a build that is broken in itself reddens every
# deploy of every service until somebody intervenes. At the bound the retry
# stops, the marker is kept so the condition stays queryable, and the run
# reports what is true: its own deploy is serving. Reach that bound through
# consecutive failures rather than manufacturing the terminal marker, so the
# rehearsal proves the counter persists and actually leads to the escape.
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
run_deploy_service api env API_VERSION="$SHA" FAIL_UP_NTH=2 > /dev/null 2>&1
check "the last allowed cascade failure still exits 3" "$?" "3"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_ATTEMPTS=3" "repeated failures reached the bound"

: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
out=$(run_deploy_service api env API_VERSION="$SHA")
check "the run succeeds rather than reddening on somebody else's image" "$?" "0"
contains "$out" "is stuck, and is not being retried" "the bound is announced"
contains "$out" "a rebuild may help if this was a bad build" "one failed image still suggests a rebuild"
absent "$out" "the code is at fault" "one failed image does not blame the code"
absent "$out" "Cascade re-deploy: badge-runner was rolled back" "no attempt was made"
absent "$(cat "$WORK/docker.log")" "pull badge-runner" "the stuck image was not pulled again"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_ATTEMPTS=3" "the terminal attempt count is retained"
check "the marker is kept, not deleted" "$([ -f "$WORK/state/needs-redeploy.env" ] && echo yes || echo no)" "yes"

echo "== 16e. two failed images blame the code and name the recorded rollback target (#108)"
# A new image of the same service is a distinct failure even though its own
# retry count starts over. Once that image also reaches the bound, rebuilding
# unchanged code is no longer defensible advice; deployed.env already names the
# image that is known to serve.
NEW_SHA=$(printf %040d 8)
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
run_deploy_service badge-runner env BADGE_VERSION="$NEW_SHA" FAIL_UP=1 > /dev/null 2>&1
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_IMAGES=2" "the replacement image is counted separately"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_ATTEMPTS=1" "the replacement image starts its own retry count"

for expected in 2 3; do
  : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
  run_deploy_service api env API_VERSION="$SHA" FAIL_UP_NTH=2 > /dev/null 2>&1
  contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_ATTEMPTS=$expected" "replacement image reached attempt $expected"
done

: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
out=$(run_deploy_service api env API_VERSION="$SHA")
known_good_badge="ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)"
contains "$out" "2 different images of badge-runner have failed; the code is at fault" "two images identify a code failure"
contains "$out" "another rebuild will not help" "a rebuild is explicitly rejected"
contains "$out" "known-good image recorded in deployed.env: $known_good_badge" "the actual rollback target is named"
contains "$out" "gh workflow run deploy.yml -R Kolonie-AI/kolonie-infra -f service=badge-runner" "the recorded-image deploy is named"
absent "$out" "version=<a good full sha>" "no unknown version placeholder remains"
absent "$out" "a rebuild may help" "multi-image failure does not suggest a rebuild"
rm -f "$WORK/state/needs-redeploy.env"

echo "== 16f. an ordinary deploy failure still exits 1"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed" "$WORK/docker.log.upcount"
run_deploy_service api env API_VERSION="$SHA" FAIL_UP=1 > /dev/null 2>&1
check "a deploy failure is still 1" "$?" "1"

echo "== 17. the deploy set is ordered by dependency, and a typo is refused"
# The policy behind #31's fix: one commit produces one deploy naming several
# services, and the api has to be first because migrate() and the seed run out
# of its image. Order is imposed here, not taken from the caller — a caller that
# passes them alphabetically must not deploy a runner ahead of its schema.
check "all stays all" "$("$WORK/scripts/deploy-set.sh" all)" "all"
check "one service is itself" "$("$WORK/scripts/deploy-set.sh" api)" "api"
check "the api leads whatever order it arrives in" \
  "$("$WORK/scripts/deploy-set.sh" "moderation-runner,api" | tr '\n' ' ')" "api moderation-runner "
check "the website goes last" \
  "$("$WORK/scripts/deploy-set.sh" "website,verifier-runner,api" | tr '\n' ' ')" "api verifier-runner website "
# The rejection case. A list with one typo must not deploy the rest and report
# success — that is the silent partial deploy this whole issue is about, one
# level up.
out=$("$WORK/scripts/deploy-set.sh" "api,verifer-runner" 2>&1); rc=$?
check "a misspelled service fails" "$rc" "1"
contains "$out" "is not a deployable service" "and says which name it could not place"
out=$("$WORK/scripts/deploy-set.sh" "" 2>&1); rc=$?
check "an empty set fails rather than deploying nothing quietly" "$rc" "2"

echo "== 18. a tag recorded where a digest belongs is called out"
# #31: `record_deployment` wrote `MODERATION_IMAGE=…:latest` when a service
# deployed for the first time and had no digest and no previous record to carry
# forward. A rollback to that line resolves `:latest` on the day of the
# rollback, which is a rollback into an unknown build — the failure #12 removed.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env FAIL_DIGEST=ghcr.io/kolonie-ai/kolonie-moderation-runner)
contains "$out" "records a mutable tag where a digest belongs: MODERATION_IMAGE" "named the line that is wrong"
contains "$out" "the deploy itself succeeded; what is broken is the record of it" "and did not blame the deploy for it"
# Loud, not fatal: the health check has already passed by the time this runs, and
# painting a working deploy red is the confusion #31 is largely a complaint about.
contains "$out" "=== Deployment completed ===" "the deploy still completed"

echo "== 19. a deploy whose digests all resolve says nothing about tags"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
absent "$out" "records a mutable tag where a digest belongs" "no false alarm on a clean deploy"

echo "== 20. a failed health check quotes the container's own log before rolling back"
# #43, and the 2026-07-31 outage: nineteen runs said `not healthy after 180s:
# api(unhealthy)` and nothing else, while the sentence naming the missing
# variable sat inside the container the rollback was about to replace.
seed_known_good() {
  rm -rf "$WORK/state"; mkdir -p "$WORK/state"
  cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
}
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
STARTUP_ERROR="Error: BAN_MARK_SALT is not set. Ban marks are salted hashes of identifiers"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-api LOG_FOR=kolonie-api LOG_TEXT="$STARTUP_ERROR")
status=$?
contains "$out" "ERROR: not healthy after 5s" "still reported the health verdict"
contains "$out" "[api] $STARTUP_ERROR" "quoted the reason the container gave"
check "the run still failed" "$status" "1"
# Order is the whole point: after rollback() the container is replaced and its
# log is gone with it, so a capture that runs afterwards captures nothing.
logs_line=$(grep -n "docker logs" "$WORK/docker.log" | head -1 | cut -d: -f1)
rollback_line=$(grep -n "up -d" "$WORK/docker.log" | tail -1 | cut -d: -f1)
check "captured before the rollback ran" \
  "$([ "$logs_line" -lt "$rollback_line" ] && echo yes || echo no)" "yes"

echo "== 20b. a container that printed nothing says so, rather than showing a blank"
# An empty section reads as a broken feature and sends the reader looking for
# the log somewhere else. Nothing printed is itself a finding.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-api)
contains "$out" "api: printed nothing" "said the container was silent"
contains "$out" "the failure is therefore before its first log line" "and what that means"

echo "== 20c. a healthy deploy quotes no logs at all"
# So the feature cannot be satisfied by always dumping logs — which would put
# every container's output into a public Actions log on every deploy.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
absent "$out" "what the failing containers printed" "no log section on a healthy deploy"
absent "$(cat "$WORK/docker.log")" "docker logs" 'and "docker logs" was never called'

echo "== 20d. every failing service is quoted, not only the first"
# The next occurrence will be a different container. `UNHEALTHY=1` fails all
# three profiled services at once.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env UNHEALTHY=1 LOG_FOR=kolonie-website LOG_TEXT="listen EADDRINUSE")
contains "$out" "api: printed nothing" "api was quoted"
contains "$out" "verifier-runner: printed nothing" "verifier-runner was quoted"
contains "$out" "[website] listen EADDRINUSE" "website was quoted, with its output"

echo "== 20e. a crash loop is answered immediately rather than waited out"
# `restart: unless-stopped` means a container that throws on its first line
# never reaches `exited` — so the terminal signal is the restart count, not the
# state. A process that has died three times has answered the question, and the
# remaining wait cannot change the answer.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
started=$SECONDS
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-api CRASHLOOP_SERVICE=kolonie-api \
                    LOG_FOR=kolonie-api LOG_TEXT="$STARTUP_ERROR")
status=$?
elapsed=$((SECONDS - started))
contains "$out" "restarting in a loop and will not become healthy: api(5 restarts)" "named the crash loop"
contains "$out" "[api] $STARTUP_ERROR" "and still quoted the reason"
contains "$out" "Rollback completed" "rolled back as before"
check "the run still failed" "$status" "1"
absent "$out" "ERROR: not healthy after" "did not wait for the deadline"
check "returned a verdict inside 3s, not at the 5s deadline" \
  "$([ "$elapsed" -lt 3 ] && echo yes || echo no)" "yes"

echo "== 20f. the early verdict can be switched off, and the deadline still rules"
# EARLY_FAIL_RESTARTS=0 restores the old behaviour exactly, which is what makes
# the new behaviour reversible on the host without a deploy of this repository.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-api CRASHLOOP_SERVICE=kolonie-api EARLY_FAIL_RESTARTS=0)
contains "$out" "ERROR: not healthy after 5s" "waited for the deadline"
absent "$out" "restarting in a loop" "and said nothing about restarts"

echo "== 20g. a failed health check quotes the probe body before rollback (#106)"
# The badge-runner incident printed only `runner.started`; its health endpoint
# held the actual reason. Replaying the configured in-container request must keep
# that body before rollback replaces the failing container.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
PROBE_REASON='{"status":"stalled","loops":{"quest-refunds":{"status":"stalled","reason":"The loop is not running."}}}'
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-badge-runner \
                    PROBE_BODY_FOR=kolonie-badge-runner PROBE_BODY="$PROBE_REASON" \
                    PROBE_FAIL_FOR=kolonie-badge-runner)
status=$?
contains "$out" "[badge-runner probe] $PROBE_REASON" "quoted the health endpoint body and marked it as the probe"
contains "$out" "The loop is not running." "preserved the reason the ordinary container log omitted"
contains "$(cat "$WORK/docker.log")" "docker exec kolonie-badge-runner node -e" "ran the configured probe inside the failing container"
contains "$(cat "$WORK/docker.log")" "http://127.0.0.1:3004/health" "asked the endpoint named by the configured health check"
check "the deploy still failed" "$status" "1"
probe_line=$(grep -n "docker exec kolonie-badge-runner" "$WORK/docker.log" | head -1 | cut -d: -f1)
rollback_line=$(grep -n "up -d" "$WORK/docker.log" | tail -1 | cut -d: -f1)
check "asked the probe before rollback ran" \
  "$([ "$probe_line" -lt "$rollback_line" ] && echo yes || echo no)" "yes"

echo "== 20h. a probe that cannot be asked says why and does not block rollback"
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-badge-runner \
                    PROBE_UNREACHABLE_FOR=kolonie-badge-runner)
status=$?
contains "$out" "[badge-runner probe] container is not running" "printed why the probe could not answer"
contains "$out" "Rollback completed" "rollback still completed"
check "the run still failed for health, not diagnostics" "$status" "1"

echo "== 20i. a service with no readable health check is diagnostic, not fatal"
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-badge-runner NO_PROBE_FOR=kolonie-badge-runner)
status=$?
contains "$out" "badge-runner probe: no configured health check could be read" "said there was no probe to replay"
contains "$out" "Rollback completed" "and still rolled back"
check "the run still failed" "$status" "1"

echo "== 20j. a hanging probe is killed, reports partial output and still rolls back"
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
started=$SECONDS
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-badge-runner \
                    HEALTH_PROBE_TIMEOUT=1 PROBE_TIMEOUT_FOR=kolonie-badge-runner \
                    PROBE_PARTIAL='probe began answering')
status=$?
elapsed=$((SECONDS - started))
contains "$out" "[badge-runner probe] probe began answering" "kept bounded partial output"
contains "$out" "the output above may be partial" "said the diagnostic timed out"
contains "$out" "Rollback completed" "rollback still completed after the timeout"
check "the run still failed" "$status" "1"
# The health verdict itself takes five seconds in rehearsal. Without the hard
# probe timeout this case takes another ten; with it, the whole run stays below
# nine seconds including rollback.
check "the hard timeout did not wait for the 10s probe" "$([ "$elapsed" -lt 9 ] && echo yes || echo no)" "yes"

echo "== 21. an image requiring a variable the host does not provide is refused"
# #42, and the other half of the 2026-07-31 outage. BAN_MARK_SALT was mandatory
# in the application and absent from this repository entirely — so compose never
# interpolated it, .env never defined it, and all three of env-drift.sh's lists
# are seeded from what compose reads. It was invisible to every check the Colony
# had, and production found it nineteen times.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env DECLARING_IMAGE=kolonie-api DECLARED_VARS=KOLONIE_FUTURE_SECRET)
status=$?
contains "$out" "an image requires a variable this host does not provide" "refused the deploy"
contains "$out" "KOLONIE_FUTURE_SECRET — required by api" "named the variable and who wants it"
contains "$out" "not set by docker-compose.yml at all" "said compose had never heard of it"
contains "$out" "the container would never see it" "and what that means for the container"
check "the run failed" "$status" "1"

echo "== 21b. and it is refused before anything is recreated"
# The criterion that separates this from a warning: a deploy stopped here has
# moved nothing, so the build that was serving is still serving.
absent "$(cat "$WORK/docker.log")" "up -d" "no container was recreated"
absent "$(cat "$WORK/docker.log")" "run --rm -T api npm run migrate" "and the migration never ran"
contains "$out" "the build that was serving is still serving" "said so plainly"

echo "== 21c. a declared variable that is provided passes silently"
# So the check cannot be satisfied by refusing everything. BAN_MARK_SALT is in
# docker-compose.yml today — it was added after the outage — so providing it in
# the environment satisfies both halves.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env DECLARING_IMAGE=kolonie-api DECLARED_VARS=BAN_MARK_SALT \
                    BAN_MARK_SALT=rehearsal-fixture-not-a-secret)
contains "$out" "OK: every variable the images declare is provided" "the check passed"
contains "$out" "=== Deployment completed ===" "and the deploy ran"
absent "$out" "does not provide" "no false alarm"

echo "== 21d. an image that declares nothing still deploys"
# Every image built before kolonie-platform#75 carries no label at all. If those
# stopped deploying, this check would itself be the outage.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "OK: every variable the images declare is provided" "an undeclared image is not a failure"
contains "$out" "=== Deployment completed ===" "the deploy completed as before"

echo "== 21f. a variable compose builds itself needs no .env entry"
# DATABASE_URL is `DATABASE_URL: postgresql://kolonie:${POSTGRES_PASSWORD}@…`
# for all three services — constructed in the compose file, never present in
# .env, and correct that way. The first version of this check required every
# declared name to appear in .env too, which would have refused every deploy
# from the moment it shipped. A preflight that blocks good deploys is one
# somebody switches off, and then it is not there for the deploy it was
# written for.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env DECLARING_IMAGE=kolonie-api DECLARED_VARS=DATABASE_URL)
contains "$out" "OK: every variable the images declare is provided" "a constructed value satisfies the check"
contains "$out" "=== Deployment completed ===" "and the deploy ran"

echo "== 21g. a pass-through variable still needs something to define it"
# The trap the two cases create together: `BAN_MARK_SALT: ${BAN_MARK_SALT}` is
# both assigned and interpolated. A check that asked "is it assigned?" first
# would call it satisfied and wave through the exact 2026-07-31 failure this
# was written for. Nothing defines it here, so it must be refused.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env DECLARING_IMAGE=kolonie-api DECLARED_VARS=BAN_MARK_SALT)
status=$?
contains "$out" "BAN_MARK_SALT — required by api, passed through by docker-compose.yml but not defined" \
  "a pass-through with nothing behind it is refused"
check "the run failed" "$status" "1"

echo "== 21e. the check reports names and never a value"
# env-drift.sh states the standard in its own header, and this runs in the same
# public log. Run the case that actually *has* a value in the environment, and
# require that the value appears nowhere — asserting this against a run with no
# value set would prove nothing.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env DECLARING_IMAGE=kolonie-api DECLARED_VARS=BAN_MARK_SALT \
                    BAN_MARK_SALT=rehearsal-fixture-not-a-secret)
contains "$out" "OK: every variable the images declare is provided" "the variable was seen as provided"
absent "$out" "rehearsal-fixture-not-a-secret" "and its value reached no output"

echo "== 22. pgAdmin's profile is off unless the host is configured for it"
# #30. The `admin` profile is gated on the host's .env rather than on a
# registry probe, and this is the case that has to keep working: a host that
# never set pgAdmin up must deploy exactly as it did before this existed.
#
# The alternative — pgAdmin in `full`, as #30 proposed — puts a container that
# cannot start without PGADMIN_PASSWORD into the profile every kolonie-platform
# merge deploys, and healthcheck() below rolls the whole stack back for any
# unhealthy service in it. That is #7 and #93's shape: an application the
# Colony depends on, taken down by a variable belonging to one that it does not.
rm -rf "$WORK/state"; : > "$WORK/docker.log"; rm -f "$WORK/.env"
out=$(run_deploy env)
contains "$out" "PGADMIN_PASSWORD is not set on this host — skipping --profile admin" "said why it skipped it"
absent "$(cat "$WORK/docker.log")" "--profile admin" "no admin profile in any compose call"
contains "$(grep 'up -d' "$WORK/docker.log")" "compose --profile full --profile website --profile workplace up -d" "the other profiles are untouched"
contains "$out" "=== Deployment completed ===" "and the deploy ran as before"

echo "== 22b. a host that defines it gets pgAdmin pulled, started and health-checked"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
printf 'POSTGRES_PASSWORD=x\nPGADMIN_EMAIL=a@b.example\nPGADMIN_PASSWORD=rehearsal-fixture-not-a-secret\n' > "$WORK/.env"
out=$(run_deploy env)
contains "$out" "PGADMIN_PASSWORD is set on this host — including --profile admin" "activated the profile"
contains "$(grep 'up -d' "$WORK/docker.log")" "--profile admin" "started it with everything else"
contains "$(cat "$WORK/docker.log")" "pull pgadmin" "and pulled it"
contains "$out" "OK: pgadmin (healthy)" "and asserted its health like any other service"
absent "$out" "rehearsal-fixture-not-a-secret" "the value reached no output"

echo "== 22v. a leftover Vikunja secret file cannot turn the retired profile back on (#252)"
# The live teardown removes this file, but a restored backup or an interrupted
# operator run must not be able to resurrect the rejected reference on the next
# deploy. The repository no longer has a profile for the file to activate.
rm -rf "$WORK/state"; : > "$WORK/docker.log"; rm -f "$WORK/.env"
mkdir -p "$WORK/secrets"
printf 'VIKUNJA_SERVICE_SECRET=rehearsal-fixture-not-a-secret\n' > "$WORK/secrets/vikunja-reference.env"
out=$(run_deploy env)
absent "$out" "--profile vikunja-reference" "the leftover secret does not activate the retired profile"
absent "$(cat "$WORK/docker.log")" "--profile vikunja-reference" "no compose call includes the retired profile"
# A future reintroduction of the compose block must fail this rehearsal even if
# deploy.sh itself still ignores the leftover secret file.
compose_effective=$(grep -v '^[[:space:]]*#' "$ROOT/docker-compose.yml")
absent "$compose_effective" "vikunja-reference:" "the retired service is absent from compose"
absent "$compose_effective" "vikunja_reference_data:" "the retired volume is absent from compose"
rm -f "$WORK/secrets/vikunja-reference.env"

echo "== 22c. an empty PGADMIN_PASSWORD= line does not count as configured"
# A key with no value is how a half-finished .env edit looks, and it is the
# state that would crash-loop the container. `grep -qE '=.'` requires a
# character after the `=` for exactly this reason.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
printf 'POSTGRES_PASSWORD=x\nPGADMIN_PASSWORD=\n' > "$WORK/.env"
out=$(run_deploy env)
contains "$out" "PGADMIN_PASSWORD is not set on this host" "treated an empty value as unset"
absent "$(cat "$WORK/docker.log")" "--profile admin" "and left the profile off"

echo "== 22d. an unhealthy pgAdmin still rolls back — it is not exempt once it is in"
# The trade the gate buys is narrow and worth stating: once an operator has
# configured pgAdmin, it is a service in the active profiles like any other, and
# healthcheck() makes no exceptions. The gate stops an *unconfigured* host from
# being broken by it; it does not make a configured one immune.
seed_known_good; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
printf 'POSTGRES_PASSWORD=x\nPGADMIN_PASSWORD=rehearsal-fixture-not-a-secret\n' > "$WORK/.env"
out=$(run_deploy env UNHEALTHY_SERVICE=kolonie-pgadmin || true)
contains "$out" "pgadmin(unhealthy)" "named pgadmin as the failing service"
contains "$out" "Rollback completed" "and rolled back"
rm -f "$WORK/.env"

echo "== 23. the support triage runner deploys like the other two runners (kolonie-platform#105)"
# A fifth image threaded through resolve_image, pin, record_deployment, rollback
# and the cascade. Each of those decides whether containers live or die, which is
# what the header of this file says earns a case.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "support-triage-runner: ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:" "pinned to a digest like the rest"
contains "$(cat "$WORK/state/deployed.env")" "TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:" "and recorded, so a rollback has somewhere to go"

echo "== 23b. a host whose last record predates this service still deploys"
# The state every host is in on the day this ships: deployed.env has four lines
# and the fifth service has never run. It must resolve from the named version
# rather than refusing the whole deploy.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(run_deploy env TRIAGE_VERSION="$SHA")
contains "$out" "=== Deployment completed ===" "an absent fifth line is not a refusal"
# Asserted through `image inspect` rather than `pull -q`: detect_profile only
# probes the api and the website — they are what decide which compose profiles
# come up — so the fifth image's resolved tag is observable where pin() reads its
# digest, and nowhere earlier.
contains "$(cat "$WORK/docker.log")" "ghcr.io/kolonie-ai/kolonie-support-triage-runner:$SHA" "it resolved to the version it was told, not to a default"
absent "$(cat "$WORK/state/deployed.env")" "kolonie-support-triage-runner:latest" "and never recorded the mutable tag"

echo "== 23c. and a host with no record and no version named is still refused"
# The other half: absent must not silently become `latest`. This is #12's rule
# applying to the new service on its first day rather than being learned again.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env || true)
contains "$out" "support-triage-runner: no version given and none recorded" "named the service it could not resolve"

echo "== 23d. a single-service triage deploy leaves the other four digests alone"
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
seed_known_good_five() {
  mkdir -p "$WORK/state"
  cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
}
seed_known_good_five; : > "$WORK/docker.log"
out=$(run_deploy_service support-triage-runner env TRIAGE_VERSION="$SHA")
recorded=$(cat "$WORK/state/deployed.env")
contains "$recorded" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "api digest carried over untouched"
contains "$recorded" "MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)" "moderation digest carried over untouched"
absent "$recorded" "TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)" "triage digest was replaced"
contains "$recorded" "BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)" "badge digest carried over untouched"

echo "== 23e. an unhealthy triage runner rolls the deploy back, and records itself for the cascade"
# It reads a schema the api migrates, so it is in the class of service that can
# deploy ahead of its own migration — the failure #29 exists for.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service support-triage-runner env TRIAGE_VERSION="$SHA" FAIL_UP=1)
contains "$out" "Rollback completed" "rolled back"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_SERVICE=support-triage-runner" "marker names it"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-support-triage-runner:$SHA" "marker carries the tag it meant to ship"

echo "== 23f. and the next successful deploy cascades it back"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env)
contains "$out" "Cascade re-deploy: support-triage-runner was rolled back" "cascade triggered for the new service"
contains "$out" "Cascade re-deploy of support-triage-runner completed" "and completed"

echo "== 23g. it is deployed after the api and before the website"
check "the api still leads" \
  "$("$WORK/scripts/deploy-set.sh" "support-triage-runner,api" | tr '\n' ' ')" "api support-triage-runner "
check "the website still goes last" \
  "$("$WORK/scripts/deploy-set.sh" "website,support-triage-runner,api" | tr '\n' ' ')" "api support-triage-runner website "

echo "== 23h. the badge runner is threaded through the same five places (kolonie-infra#76)"
# A sixth image, and the reason it gets its own cases rather than being assumed
# to work because the fifth did: `deploy.sh` resolves images by name in half a
# dozen places, and a name threaded through some of them is worse than none —
# the deploy succeeds and records a build that is not running. Each assertion
# below fails on main before this change.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "badge-runner:          ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:" "pinned to a digest like the rest"
contains "$(cat "$WORK/state/deployed.env")" "BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:" "and recorded, so a rollback has somewhere to go"

echo "== 23i. a host whose last record predates the badge runner still deploys"
# The state this host is in on the day it ships: five recorded images and a sixth
# that has never run. It must resolve from the named version rather than refusing
# the whole deploy — and refuse when nothing names it, which is 23j.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(run_deploy env BADGE_VERSION="$SHA")
contains "$out" "=== Deployment completed ===" "an absent sixth line is not a refusal"
contains "$(cat "$WORK/docker.log")" "ghcr.io/kolonie-ai/kolonie-badge-runner:$SHA" "it resolved to the version it was told, not to a default"
absent "$(cat "$WORK/state/deployed.env")" "kolonie-badge-runner:latest" "and never recorded the mutable tag"
# The website is the last field of the recorded state and stays the last field —
# a sixth image inserted after it would be read as the website's own digest by
# every host whose record was written before today.
contains "$(cat "$WORK/state/deployed.env")" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:" "the website digest is still read as the website's"

echo "== 23j. and a host with no record and no version named is still refused"
# Re-seeded, because 23i has just recorded the badge digest — resolving from that
# record is the very thing this case must not be allowed to do.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env || true)
contains "$out" "badge-runner: no version given and none recorded" "named the service it could not resolve"
absent "$(cat "$WORK/docker.log")" "kolonie-badge-runner:latest" "and did not quietly reach for the mutable tag"

echo "== 23k. a single-service badge deploy leaves the other five digests alone"
seed_known_good_five; : > "$WORK/docker.log"
out=$(run_deploy_service badge-runner env BADGE_VERSION="$SHA")
recorded=$(cat "$WORK/state/deployed.env")
contains "$recorded" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "api digest carried over untouched"
contains "$recorded" "TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)" "triage digest carried over untouched"
absent "$recorded" "BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)" "badge digest was replaced"
contains "$out" "Deploying service: badge-runner" "and it deployed that service alone"

echo "== 23l. an unhealthy badge runner rolls back and records itself for the cascade"
# It reads and writes badge rows through packages/db, so it is in the class of
# service that can deploy ahead of its own migration — the failure #29 exists for.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service badge-runner env BADGE_VERSION="$SHA" FAIL_UP=1)
contains "$out" "Rollback completed" "rolled back"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_SERVICE=badge-runner" "marker names it"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-badge-runner:$SHA" "marker carries the tag it meant to ship"

echo "== 23m. and the next successful deploy cascades it back"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env)
contains "$out" "Cascade re-deploy: badge-runner was rolled back" "cascade triggered for the sixth image"
contains "$out" "Cascade re-deploy of badge-runner completed" "and completed"

echo "== 23n. it is deployed after the api and before the website"
check "the api still leads" \
  "$("$WORK/scripts/deploy-set.sh" "badge-runner,api" | tr '\n' ' ')" "api badge-runner "
check "the website still goes last" \
  "$("$WORK/scripts/deploy-set.sh" "website,badge-runner,api" | tr '\n' ' ')" "api badge-runner website "
check "and it sits behind the other three runners" \
  "$("$WORK/scripts/deploy-set.sh" "badge-runner,support-triage-runner,moderation-runner" | tr '\n' ' ')" "moderation-runner support-triage-runner badge-runner "

echo "== 23o. the doctor runner is threaded through the same places (kolonie-infra#192)"
# A seventh image, and it gets its own cases for the reason the sixth did: a name
# threaded through some of `deploy.sh`'s half-dozen resolution sites and not all
# of them is worse than none — the deploy succeeds and records a build that is
# not running.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "doctor-runner:         ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:" "pinned to a digest like the rest"
contains "$(cat "$WORK/state/deployed.env")" "DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:" "and recorded, so a rollback has somewhere to go"

echo "== 23p. a host whose last record predates the doctor runner still deploys"
# The state the host is in on the day this ships: six recorded images and a
# seventh that has never run.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(run_deploy env DOCTOR_VERSION="$SHA")
contains "$out" "=== Deployment completed ===" "an absent seventh line is not a refusal"
contains "$(cat "$WORK/docker.log")" "ghcr.io/kolonie-ai/kolonie-doctor-runner:$SHA" "it resolved to the version it was told, not to a default"
absent "$(cat "$WORK/state/deployed.env")" "kolonie-doctor-runner:latest" "and never recorded the mutable tag"
# The same property 23i asserts for the sixth image, and the reason the doctor's
# field went in *before* the website's rather than after it: a record written
# before today is read by `${PREV_STATE##*|}` for the website, so the website
# stays the last field forever.
contains "$(cat "$WORK/state/deployed.env")" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:" "the website digest is still read as the website's"

echo "== 23q. and a host with no record and no version named is still refused"
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env || true)
contains "$out" "doctor-runner: no version given and none recorded" "named the service it could not resolve"
absent "$(cat "$WORK/docker.log")" "kolonie-doctor-runner:latest" "and did not quietly reach for the mutable tag"

echo "== 23r. a single-service doctor deploy leaves the other six digests alone"
seed_known_good_five; : > "$WORK/docker.log"
out=$(run_deploy_service doctor-runner env DOCTOR_VERSION="$SHA")
recorded=$(cat "$WORK/state/deployed.env")
contains "$recorded" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "api digest carried over untouched"
contains "$recorded" "BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)" "badge digest carried over untouched"
absent "$recorded" "DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)" "doctor digest was replaced"
contains "$out" "Deploying service: doctor-runner" "and it deployed that service alone"

echo "== 23s. an unhealthy doctor runner rolls back and records itself for the cascade"
# It reads the traffic rollup through packages/db, so it is in the class of
# service that can deploy ahead of its own migration — the failure #29 exists for.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service doctor-runner env DOCTOR_VERSION="$SHA" FAIL_UP=1)
contains "$out" "Rollback completed" "rolled back"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_SERVICE=doctor-runner" "marker names it"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-doctor-runner:$SHA" "marker carries the tag it meant to ship"

echo "== 23t. and the next successful deploy cascades it back"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env)
contains "$out" "Cascade re-deploy: doctor-runner was rolled back" "cascade triggered for the seventh image"
contains "$out" "Cascade re-deploy of doctor-runner completed" "and completed"

echo "== 23u. it is deployed after the badge runner and before the website"
check "the api still leads" \
  "$("$WORK/scripts/deploy-set.sh" "doctor-runner,api" | tr '\n' ' ')" "api doctor-runner "
check "the website still goes last" \
  "$("$WORK/scripts/deploy-set.sh" "website,doctor-runner,api" | tr '\n' ' ')" "api doctor-runner website "
check "and it sits behind the other four runners" \
  "$("$WORK/scripts/deploy-set.sh" "doctor-runner,badge-runner,support-triage-runner,moderation-runner" | tr '\n' ' ')" "moderation-runner support-triage-runner badge-runner doctor-runner "

echo "== 23v. the workplace is threaded through the same places (kolonie-infra#243)"
# An eighth image, and it gets its own cases for the reason the fifth, sixth and
# seventh did: deploy.sh resolves images by name in half a dozen places, and a
# name threaded through some of them and not all is worse than none — the deploy
# succeeds and records a build that is not running. Each assertion below fails on
# main before this change.
#
# It is also the first image since the website that is a public face rather than
# a runner: a second nginx container behind its own router (#241), so the thing
# it can break that a runner cannot is a host answering 502 while every check
# here is green. That is the state workplace.kolonie.ai is in on the day this
# ships.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)
contains "$out" "workplace:             ghcr.io/kolonie-ai/kolonie-workplace@sha256:" "pinned to a digest like the rest"
contains "$(cat "$WORK/state/deployed.env")" "WORKPLACE_IMAGE=ghcr.io/kolonie-ai/kolonie-workplace@sha256:" "and recorded, so a rollback has somewhere to go"
# Its own profile, probed on its own — the website's blast-radius argument, and
# the issue's acceptance criteria name it.
contains "$(grep 'up -d' "$WORK/docker.log")" "--profile workplace" "and it came up under its own profile"

echo "== 23w. a host whose last record predates the workplace still deploys"
# The state every host is in on the day this ships: seven recorded images and an
# eighth that has never run. It must resolve from the named version rather than
# refusing the whole deploy.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(run_deploy env WORKPLACE_VERSION="$SHA")
contains "$out" "=== Deployment completed ===" "an absent eighth line is not a refusal"
contains "$(cat "$WORK/docker.log")" "ghcr.io/kolonie-ai/kolonie-workplace:$SHA" "it resolved to the version it was told, not to a default"
absent "$(cat "$WORK/state/deployed.env")" "kolonie-workplace:latest" "and never recorded the mutable tag"
# The property 23i and 23p both assert, and the reason the workplace's field goes
# *after* the website's rather than replacing it as the last field read by
# `${PREV_STATE##*|}`: an eighth field could not be inserted before the website
# without every pre-existing record misreading it, so the workplace becomes the
# new last field and the website moves to cut -f7. A record written before today
# has no eighth field, and cut answers empty for it — which is exactly the
# absent-line case 23w and 23x are about.
contains "$(cat "$WORK/state/deployed.env")" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:" "the website digest is still read as the website's"

echo "== 23x. a host with no workplace record takes the one reviewed bootstrap digest"
# Re-seeded, because 23w has just recorded another workplace digest. The first
# infra deploy after this merge receives no version from an application build,
# so deploy.sh has to carry #243's exact digest once; otherwise the compose
# service lands and the deploy refuses before it can record the image.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(NO_VERSIONS=1 run_deploy env)
contains "$out" "workplace:             ghcr.io/kolonie-ai/kolonie-workplace@sha256:4a8a98f485bfbeab84bdb3c5192780661331935131c23881698b853ef80bc794" "used the exact digest #243 approved"
contains "$(cat "$WORK/state/deployed.env")" "WORKPLACE_IMAGE=ghcr.io/kolonie-ai/kolonie-workplace@sha256:4a8a98f485bfbeab84bdb3c5192780661331935131c23881698b853ef80bc794" "recorded that digest as the rollback target"
absent "$(cat "$WORK/docker.log")" "kolonie-workplace:latest" "and did not quietly reach for the mutable tag"

echo "== 23y. an unreachable workplace image does not take the other profiles down"
# The failure #1 is about, arriving from the eighth image. docker compose pull
# fails the whole command for a single missing image, so a workplace build that
# has not been pushed must degrade to its own host answering 502 — not to api
# and website going down with it.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env UNREACHABLE=ghcr.io/kolonie-ai/kolonie-workplace)
contains "$out" "is not reachable. workplace.kolonie.ai will answer 502." "said which host is affected, and only that host"
contains "$out" "=== Deployment completed ===" "and the deploy still completed"
contains "$(cat "$WORK/docker.log")" "--profile full" "the api profile is untouched"
contains "$(cat "$WORK/docker.log")" "--profile website" "and so is the website's"
absent "$(grep 'up -d' "$WORK/docker.log")" "--remove-orphans" "and an incomplete view does not assert orphans"

echo "== 23z. it is deployed last, behind even the website"
# The website's own argument, extended: if anything in the sequence is going to
# fail it should fail before a public face of the Colony changes, and the
# workplace is the second such face and the one with the least behind it.
check "the api still leads" \
  "$("$WORK/scripts/deploy-set.sh" "workplace,api" | tr '\n' ' ')" "api workplace "
check "and it goes after the website" \
  "$("$WORK/scripts/deploy-set.sh" "workplace,website,api" | tr '\n' ' ')" "api website workplace "

echo "== 23aa. a single-service workplace deploy leaves the other seven digests alone"
seed_known_good_five; : > "$WORK/docker.log"
out=$(run_deploy_service workplace env WORKPLACE_VERSION="$SHA")
recorded=$(cat "$WORK/state/deployed.env")
contains "$recorded" "API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)" "api digest carried over untouched"
contains "$recorded" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)" "website digest carried over untouched"
absent "$recorded" "WORKPLACE_IMAGE=ghcr.io/kolonie-ai/kolonie-workplace@sha256:$(printf %064d 9)" "workplace digest was replaced"
contains "$out" "Deploying service: workplace" "and it deployed that service alone"

echo "== 23ab. an unhealthy workplace rolls back and records itself for the cascade"
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service workplace env WORKPLACE_VERSION="$SHA" FAIL_UP=1)
contains "$out" "Rollback completed" "rolled back"
contains "$out" "no previous workplace build is recorded" "said why the failed new container is not a rollback target"
absent "$(grep 'up -d' "$WORK/docker.log" | tail -n1)" "--profile workplace" "and restored the established profiles without retrying it"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_SERVICE=workplace" "marker names it"
contains "$(cat "$WORK/state/needs-redeploy.env")" "NEEDS_REDEPLOY_TAG=ghcr.io/kolonie-ai/kolonie-workplace:$SHA" "marker carries the tag it meant to ship"

echo "== 23ac. and the next successful deploy cascades it back"
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env)
contains "$out" "Cascade re-deploy: workplace was rolled back" "cascade triggered for the eighth image"
contains "$out" "Cascade re-deploy of workplace completed" "and completed"

echo "== 23ad. the service itself: healthcheck shape and profile, read off the compose file (kolonie-infra#243)"
# The properties no stub can reach, asserted the way rehearse-pin case 11 asserts
# the PIN-NOT-SET fallbacks: by reading docker-compose.yml. The healthcheck must
# hit 127.0.0.1 — kolonie-infra#11, days of an unhealthy website that was serving
# — and /health rather than /, so a broken bundle cannot look healthy; and the
# service must not sit in the full profile, or healthcheck() could roll the API
# back over a failed prototype.
compose="$ROOT/docker-compose.yml"
health=$(awk '/^  workplace:$/ { inside = 1 } inside && /^[[:space:]]*test:/ { print; exit }' "$compose")
check "the healthcheck probes 127.0.0.1, never localhost" \
  "$(printf '%s' "$health" | grep -qF 'http://127.0.0.1:80/health' && echo yes || echo no)" "yes"
check "and not the mutable root path" \
  "$(printf '%s' "$health" | grep -qF 'http://127.0.0.1:80/"' && grep -qF 'http://127.0.0.1:80/health' <<<"$health" && echo no || echo yes)" "yes"
profiles=$(awk '/^  workplace:$/ { inside = 1 } inside && /^    profiles:/ { getline; print; exit }' "$compose" | tr -d ' -')
check "it is not in the full profile" \
  "$([ "$profiles" = workplace ] && echo yes || echo no)" "yes"
check "the router's service URL is untouched" \
  "$(grep -c 'url: "http://kolonie-workplace:80"' "$ROOT/traefik/dynamic/routes.yml")" "1"

echo "== 24. an image this deploy does not touch, and has never recorded, is not fatal"
# The deadlock introducing kolonie-platform#105 walked into. `deploy.sh api`
# resolves every image, so on a host with no recorded build for a *new* service
# the api deploy was refused — several iterations before the one that would have
# recorded it, and the caller deploys the list in order, so the failure always
# came first. A service could therefore never be introduced.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
out=$(run_deploy_service api env API_VERSION="$SHA" TRIAGE_VERSION="")
contains "$out" "support-triage-runner: no build recorded, and this deploy does not touch it" "said so, at WARN"
contains "$out" "=== Deployment completed ===" "and deployed the service it was asked for"
absent "$out" "support-triage-runner: no version given and none recorded" "did not refuse over an unrelated image"

echo "== 24b. and it never becomes :latest on the way through"
# The trade this must not make. #12 removed the mutable tag from the deploy path;
# an unresolved image becomes empty, and empty is inert.
absent "$(cat "$WORK/docker.log")" "kolonie-support-triage-runner:latest" "no mutable tag anywhere in the run"
absent "$(cat "$WORK/state/deployed.env")" "kolonie-support-triage-runner:latest" "and none recorded"

echo '== 24c. an all-deploy still refuses, because up -d with no service named starts everything'
# The half that must not be relaxed: with no service named, compose creates every
# container, so an unresolved image really would be started from its compose
# default.
rm -rf "$WORK/state"; mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"
# Cleared through `env`, after run_deploy has computed its defaults: its own
# `${TRIAGE_VERSION:-some-sha}` treats an empty string as unset and would put
# the default back.
out=$(run_deploy env TRIAGE_VERSION="" || true)
contains "$out" "support-triage-runner: no version given and none recorded" "an all-deploy still refuses"
absent "$(cat "$WORK/docker.log")" "up -d" "and nothing was recreated"

echo "== 25. a container that has never existed does not fail a deploy of something else"
# The third face of the introduction problem, and the one that reached production
# on 2026-08-01: `support-triage-runner` entered the `full` profile, `deploy.sh
# api` created only the api, and healthcheck() then waited 180s for a container
# nobody had asked it to create — and rolled the whole deploy back.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy_service api env API_VERSION="$SHA" ABSENT_CONTAINER=kolonie-support-triage-runner)
contains "$out" "support-triage-runner has no container at all, and this deploy touches api" "said what it skipped and why"
contains "$out" "=== Deployment completed ===" "and the deploy it was asked for finished"
absent "$out" "Rolling back" "nothing was rolled back"

echo "== 25b. but a container that is merely unhealthy still fails"
# The guard this must not remove: a migration that broke an older build is
# exactly what checking every profiled service is for.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
# verifier-runner rather than moderation-runner: the stub's `config --services`
# is the list healthcheck() iterates, and naming a service absent from it would
# assert on a check that never runs.
out=$(run_deploy_service api env API_VERSION="$SHA" UNHEALTHY_SERVICE=kolonie-verifier-runner || true)
contains "$out" "ERROR: not healthy after 5s" "an existing unhealthy service still fails the deploy"
contains "$out" "verifier-runner(unhealthy)" "and is named"

echo "== 25c. and an all-deploy asserts everything, missing container or not"
# With no service named, compose creates every container — so one that is absent
# afterwards is a failure rather than a service nobody asked for.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env ABSENT_CONTAINER=kolonie-support-triage-runner || true)
contains "$out" "ERROR: not healthy after 5s" "an all-deploy still asserts it"
absent "$out" "not asserting its health" "and does not skip it"

echo "== 26. a running container with no health check at all does not fail a deploy"
# #68 put the first such service on this host: `kolonie-loki` ships without a
# health check, because its image is distroless and holds no shell to run one
# with. healthcheck()'s `missing` branch was written for exactly this and was
# never reached — Docker writes an empty line to stdout *before* failing on the
# template, so `|| echo missing` produced a two-line status matching no `case`
# arm, and the service stayed pending until the timeout took the whole stack
# back. It cost a rolled-back deploy on 2026-08-04, with every container in it
# healthy.
#
# Fails on main before the fix with "ERROR: not healthy after 5s: loki(", which
# is that two-line status printed into a message.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env NO_HEALTHCHECK_SERVICE=kolonie-verifier-runner || true)
absent "$out" "ERROR: not healthy" "a container with no health check is not read as unhealthy"
absent "$out" "Rolling back" "and nothing was rolled back over it"
contains "$out" "=== Deployment completed ===" "the deploy finished"

echo "== 26b. and it is reported as such rather than as a blank"
# The summary loop reads the same field the same way, so it had the same defect —
# cosmetic, but a line that renders as two is how somebody concludes the deploy
# did something strange.
contains "$out" "OK: verifier-runner (no health check)" "the summary names it"

echo "== 26c. but a container that is genuinely gone still fails"
# The guard this must not remove. Both cases read as "no health status"; what
# tells them apart is whether the container runs, and that distinction is the
# whole of the `missing` branch.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env ABSENT_CONTAINER=kolonie-verifier-runner || true)
contains "$out" "ERROR: not healthy after 5s" "an absent container still fails an all-deploy"

echo "== 27. a mounted configuration file newer than its container is recreated"
# #84: compose compares its own definition of a service — image, command,
# environment, the mounts themselves — and a change *inside* a bind-mounted file
# is in none of those. So `promtail.yml` lands on the host, `up -d` reports
# success, and the container keeps running the pipeline it parsed at startup.
# Reproduced twice on production on 2026-08-05.
#
# Fails on main before the fix: nothing recreates anything, and the deploy is
# green.
mkdir -p "$WORK/promtail"
echo "the new pipeline" > "$WORK/promtail/promtail.yml"
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env EXTRA_SERVICES=promtail STARTED_AT=2026-01-01T00:00:00Z \
        MOUNTS_FOR=kolonie-promtail \
        MOUNTS_LIST="$WORK/promtail/promtail.yml|/etc/promtail/promtail.yml" || true)
contains "$out" "is newer than the container" "the staleness is named"
contains "$out" "read once, at startup" "and why it matters is said"
contains "$(cat "$WORK/docker.log")" "up -d --force-recreate promtail" "promtail is recreated"

echo "== 27b. a container newer than its configuration is left alone"
# The other half, and the one that stops this from being a blanket
# --force-recreate. The issue is explicit that it is not asking for that.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env EXTRA_SERVICES=promtail STARTED_AT=2036-01-01T00:00:00Z \
        MOUNTS_FOR=kolonie-promtail \
        MOUNTS_LIST="$WORK/promtail/promtail.yml|/etc/promtail/promtail.yml" || true)
absent "$(cat "$WORK/docker.log")" "--force-recreate" "nothing is recreated"
contains "$out" "every container is at least as new" "and the deploy says so rather than staying silent"

echo "== 27c. a bind-mounted directory is never recreated, however new"
# Traefik's `dynamic/` is the case this protects: Traefik watches those files
# itself and reloads them, so recreating it would be a restart nobody asked for.
# The exclusion is by file type rather than by a list of paths, which is what
# keeps it from going out of step with docker-compose.yml.
mkdir -p "$WORK/traefik/dynamic"
echo "routes" > "$WORK/traefik/dynamic/routes.yml"
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env EXTRA_SERVICES=traefik STARTED_AT=2026-01-01T00:00:00Z \
        MOUNTS_FOR=kolonie-traefik \
        MOUNTS_LIST="$WORK/traefik/dynamic|/dynamic" || true)
absent "$(cat "$WORK/docker.log")" "--force-recreate" "a directory is not configuration read once"

echo "== 27d. a service with no bind mounts at all is not asked about"
# Every application container is this case: named volumes only. The check must
# be silent for them rather than reporting something it did not measure.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env || true)
absent "$(cat "$WORK/docker.log")" "--force-recreate" "nothing is recreated on an ordinary deploy"
contains "$out" "every container is at least as new" "and it is stated once, not per service"

echo "== 28. a host with no Telegram configuration deploys exactly as before"
# kolonie-infra#142. The operator desk on Telegram is three variables the api
# reads, and every one of them is optional: absent, an operator is reached by
# mail, which is what every host did before the bot existed and what a host
# without a bot must keep doing. The failure this guards against is the one #7
# and #93 both are — a variable made mandatory somewhere, and every deploy
# refused until somebody finds out where.
seed_known_good_five; : > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env || true)
contains "$out" "=== Deployment completed ===" "the deploy ran with none of the three set"
absent "$out" "TELEGRAM_" "and named none of them, so nothing waits on a bot"

echo "== 28b. and the compose file is where that has to be asserted"
# **The stub cannot see this and it is honest to say so.** `docker` is a stub
# here, so `${VAR:?}` never gets interpolated and case 28 above would keep
# passing the day somebody made one of these mandatory. Compose's own file is
# the artefact that decides it, so the assertion is against the text: each of
# the three carries `:-`, which is what makes an unset value a working
# configuration rather than a refused deploy.
for v in TELEGRAM_OPERATOR_BOT_TOKEN TELEGRAM_OPERATOR_BOT_USERNAME TELEGRAM_WEBHOOK_SECRET; do
  line=$(grep -F "      $v: " "$ROOT/docker-compose.yml" || true)
  check "$v is passed to a service at all" "$([ -n "$line" ] && echo yes || echo no)" "yes"
  check "$v is optional (\${$v:-})" "$(grep -qF "\${$v:-}" <<<"$line" && echo yes || echo no)" "yes"
  check "$v is documented in .env.example" \
    "$(grep -qE "^#?$v=" "$ROOT/.env.example" && echo yes || echo no)" "yes"
done

echo "== 29. no deploy removes a container, and a failed one least of all (#188)"
# A recreate renames the container it is replacing to `<12 hex>_<name>`, and a
# deploy that fails part-way leaves that rename on the host. #188 asked where
# the sweep belongs; the answer is `image-prune.sh`, and this case is the half
# of it that has to be asserted *here*, because it is a statement about what
# `deploy.sh` does not do.
#
# **A failed deploy sweeps nothing on purpose.** The leftover is the only
# artefact of the failure that outlives the run log — #183 was looked at two
# days after the log had expired — so the script that owns the rollback is the
# last place that may remove it. The weekly sweeper does, a full cycle later,
# with the rollback margin still in front of it.
rm -rf "$WORK/state"; : > "$WORK/docker.log"
run_deploy env > /dev/null 2>&1
absent "$(cat "$WORK/docker.log")" "docker rm " "a successful deploy removed no container"

mkdir -p "$WORK/state"
cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=19990101_000000
API_IMAGE=ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf %064d 1)
RUNNER_IMAGE=ghcr.io/kolonie-ai/kolonie-verifier-runner@sha256:$(printf %064d 2)
MODERATION_IMAGE=ghcr.io/kolonie-ai/kolonie-moderation-runner@sha256:$(printf %064d 3)
TRIAGE_IMAGE=ghcr.io/kolonie-ai/kolonie-support-triage-runner@sha256:$(printf %064d 8)
BADGE_IMAGE=ghcr.io/kolonie-ai/kolonie-badge-runner@sha256:$(printf %064d 6)
DOCTOR_IMAGE=ghcr.io/kolonie-ai/kolonie-doctor-runner@sha256:$(printf %064d 7)
WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf %064d 4)
EOF
: > "$WORK/docker.log"; rm -f "$WORK/docker.log.upfailed"
out=$(run_deploy env FAIL_UP=1)
contains "$out" "Rollback completed" "the deploy failed and rolled back, as this case needs it to"
absent "$(cat "$WORK/docker.log")" "docker rm " "and the rollback removed no container either"
absent "$(grep 'up -d' "$WORK/docker.log" | tail -n1)" "--remove-orphans" "nor did its own up -d pass --remove-orphans, which would have taken the leftover as an orphan"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
