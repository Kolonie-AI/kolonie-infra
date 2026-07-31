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
      # the tag is the last argument; return the digest for its own repo, plus a
      # decoy from another repo to prove the prefix match is doing work.
      for tag in "$@"; do :; done
      repo="${tag%%:*}"
      if [ "${FAIL_DIGEST:-}" = "$repo" ]; then exit 1; fi
      echo "ghcr.io/someone-else/other@sha256:$(printf %064d 0)"
      echo "${repo}@sha256:$(echo -n "$repo" | sha256sum | cut -c1-64)"
      exit 0 ;;
  "compose"*)
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
            echo -e "api\nverifier-runner\nwebsite"
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
      case "$*" in
        *"{{.State.Health.Status}}"*|*"{{.State.Running}}"*|*"{{.RestartCount}}"*) ;;
        *) echo "STUB: unknown docker inspect format: $*" >&2; exit 125 ;;
      esac

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
  "login"*|"logout"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

run_deploy() {
  local av="${API_VERSION:-some-sha}" rv="${RUNNER_VERSION:-some-sha}" mv="${MODERATION_VERSION:-some-sha}" wv="${WEBSITE_VERSION:-some-sha}"
  if [ "${NO_VERSIONS:-}" = "1" ]; then av=""; rv=""; mv=""; wv=""; fi
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" WEBSITE_VERSION="$wv" \
  DOCKER_LOG="$WORK/docker.log" \
  PATH="$BIN:$PATH" DEPLOY_DIR="$WORK" GHCR_TOKEN=x HEALTH_TIMEOUT=5 \
  "$@" bash "$WORK/scripts/deploy.sh" all 2>&1
}

# Same, for a deploy of one named service — which is what a build in
# kolonie-platform triggers.
run_deploy_service() {
  local av="${API_VERSION:-some-sha}" rv="${RUNNER_VERSION:-some-sha}" mv="${MODERATION_VERSION:-some-sha}" wv="${WEBSITE_VERSION:-some-sha}"
  local service="$1"; shift
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" WEBSITE_VERSION="$wv" \
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
contains "$(cat "$WORK/docker.log")" "compose --profile full --profile website up -d --remove-orphans" "up -d ran"

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
contains "$(cat "$WORK/docker.log")" "compose --profile full --profile website pull verifier-runner" "cascade pulled the runner"

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

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]

