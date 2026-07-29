#!/bin/bash
# Kolonie AI — Health Check Script
# Checks container health status via Docker
#
# **A deploy gate, and only that.** It runs at the end of a deploy and its
# non-zero exit is what stops one. That makes it the wrong tool for noticing a
# container that goes unhealthy at three in the morning — it only ever runs when
# somebody deploys, which is how kolonie-website stayed unhealthy for days while
# serving every request correctly (#11).
#
# The continuous reader is scripts/health-report.sh, piped into
# scripts/health-triage.sh by the Health Watch workflow. If you are adding
# "notice a problem" behaviour, add it there: this script must keep exiting
# non-zero on the first thing it does not like, and a gate that also tries to be
# a monitor ends up too noisy for one job and too quiet for the other.

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
FAILED=0

cd "$DEPLOY_DIR"

# Get all running containers for this project
containers=$(docker compose ps --format '{{.Name}}' 2>/dev/null)

if [ -z "$containers" ]; then
    echo "WARN: No running containers found"
    exit 1
fi

for container in $containers; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no-healthcheck")
    running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")

    if [ "$running" != "true" ]; then
        echo "FAIL: $container is not running"
        FAILED=$((FAILED + 1))
    elif [ "$status" = "unhealthy" ]; then
        echo "FAIL: $container is unhealthy"
        FAILED=$((FAILED + 1))
    elif [ "$status" = "no-healthcheck" ]; then
        echo "OK: $container (running, no healthcheck)"
    else
        echo "OK: $container ($status)"
    fi
done

exit $FAILED
