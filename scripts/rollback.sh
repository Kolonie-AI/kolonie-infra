#!/bin/bash
# Kolonie AI — Manual Rollback Script
# Usage: ./rollback.sh [service]
#
# Returns the stack to the last build that passed a health check, by digest,
# from state/deployed.env — the file scripts/deploy.sh writes after a successful
# deploy and only then.
#
# Two things this deliberately does not do, both of which it used to.
#
# **It does not restore `docker-compose.last.yml`.** That file is a rendering of
# the *configuration*, not a record of a *build*. Restoring it while every image
# was tagged `:latest` brought back the same image that had just failed, which is
# a retry wearing a rollback's clothes (#12). The snapshot is still written, for
# reading when something has gone wrong; it is no longer an input to recovery.
#
# **It never passes --remove-orphans.** That flag deletes every container absent
# from the file it is given. On 2026-07-28 it deleted api, verifier-runner and
# website in response to a single unhealthy container that was in fact serving
# every request. A rollback that destroys more than the deploy touched is not a
# safety net.

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
STATE_DIR="${DEPLOY_DIR}/state"
DEPLOYED_STATE="${STATE_DIR}/deployed.env"
SERVICE=${1:-all}

echo "=== Manual Rollback ==="
echo "Service: $SERVICE"

cd "$DEPLOY_DIR"

# Nothing recorded means nothing known-good to return to. Exiting without
# touching the containers is the answer: they may well be serving, and tearing
# them down to look decisive is how a safety net becomes the outage.
if [ ! -f "$DEPLOYED_STATE" ]; then
    echo "ERROR: no previously deployed build recorded in $DEPLOYED_STATE."
    echo "ERROR: nothing has been changed — whatever is running stays running."
    echo "ERROR: deploy.sh writes that file after a health check passes, so this host"
    echo "ERROR: has not completed a deploy since immutable pinning was introduced."
    exit 1
fi

# shellcheck disable=SC1090
set -a; . "$DEPLOYED_STATE"; set +a

echo "Returning to the build deployed at ${DEPLOYED_AT:-unknown}:"
echo "  api:             ${API_IMAGE:-unset}"
echo "  verifier-runner: ${RUNNER_IMAGE:-unset}"
echo "  website:         ${WEBSITE_IMAGE:-unset}"

# Both profiles: a human runs this on a host where the application containers
# exist, and omitting them would roll back infrastructure alone — the shape of
# the 2026-07-28 failure, one level up.
PROFILE_ARGS=(--profile full --profile website)

if [ "$SERVICE" = "all" ]; then
    docker compose "${PROFILE_ARGS[@]}" up -d
else
    docker compose "${PROFILE_ARGS[@]}" up -d "$SERVICE"
fi

echo "Waiting for services to stabilize..."
sleep 10

echo "Checking health..."
docker compose "${PROFILE_ARGS[@]}" ps

echo "=== Rollback complete ==="
echo "The database was not touched. If the failed deploy applied a migration,"
echo "read docs/disaster-recovery.md, Scenario 5, before assuming this is over."
