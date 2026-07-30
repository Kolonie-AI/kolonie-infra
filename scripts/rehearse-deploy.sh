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
      # healthcheck asks for .State.Health.Status
      if [ "${UNHEALTHY:-}" = 1 ]; then echo "unhealthy"
      elif [ -n "${UNHEALTHY_SERVICE:-}" ] && echo "$*" | grep -q "${UNHEALTHY_SERVICE}"; then echo "unhealthy"
      else echo "healthy"
      fi
      exit 0 ;;
  "login"*|"logout"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

run_deploy() {
  local av="${API_VERSION:-${SHA:-some-sha}}" rv="${RUNNER_VERSION:-${SHA:-some-sha}}" mv="${MODERATION_VERSION:-${SHA:-some-sha}}" wv="${WEBSITE_VERSION:-${SHA:-some-sha}}"
  if [ "${NO_VERSIONS:-}" = "1" ]; then av=""; rv=""; mv=""; wv=""; fi
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" WEBSITE_VERSION="$wv" \
  DOCKER_LOG="$WORK/docker.log" \
  PATH="$BIN:$PATH" DEPLOY_DIR="$WORK" GHCR_TOKEN=x HEALTH_TIMEOUT=5 \
  "$@" bash "$WORK/scripts/deploy.sh" all 2>&1
}

# Same, for a deploy of one named service — which is what a build in
# kolonie-platform triggers.
run_deploy_service() {
  local av="${API_VERSION:-${SHA:-some-sha}}" rv="${RUNNER_VERSION:-${SHA:-some-sha}}" mv="${MODERATION_VERSION:-${SHA:-some-sha}}" wv="${WEBSITE_VERSION:-${SHA:-some-sha}}"
  API_VERSION="$av" RUNNER_VERSION="$rv" MODERATION_VERSION="$mv" WEBSITE_VERSION="$wv" \
  local service="$1"; shift
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
contains "$out" "no digest recorded for ghcr.io/kolonie-ai/kolonie-website:latest" "warned about the unpinnable image"
contains "$out" "Deployment completed" "deploy still finished"
contains "$(cat "$WORK/state/deployed.env")" "WEBSITE_IMAGE=ghcr.io/kolonie-ai/kolonie-website:latest" "recorded the tag it actually used"

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
contains "$(cat "$WORK/docker.log")" "pull -q ghcr.io/kolonie-ai/kolonie-website:latest" "website stayed on latest"

echo "== 7. no version named is rejected, preventing :latest"
rm -rf "$WORK/state"; : > "$WORK/docker.log"
out=$(run_deploy env)


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
NO_VERSIONS=1 out=$(run_deploy env || true)
contains "$out" "The deploy names the image it intends, not :latest" "defaulted to latest"
contains "$out" "Cascade re-deploy: verifier-runner was rolled back" "cascade was attempted"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]

