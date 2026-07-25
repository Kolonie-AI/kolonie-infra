#!/bin/bash
# Kolonie AI — Health Check Script
# Checks container health status via Docker

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
