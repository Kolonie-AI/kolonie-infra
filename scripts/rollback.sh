#!/bin/bash
# Kolonie AI — Manual Rollback Script
# Usage: ./rollback.sh [service]

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
SERVICE=${1:-all}

echo "=== Manual Rollback ==="
echo "Service: $SERVICE"

cd "$DEPLOY_DIR"

if [ ! -f "docker-compose.last.yml" ]; then
    echo "ERROR: No previous configuration found"
    exit 1
fi

echo "Restoring previous configuration..."
docker compose -f docker-compose.last.yml up -d --remove-orphans $SERVICE

echo "Waiting for services to stabilize..."
sleep 10

echo "Checking health..."
docker compose -f docker-compose.last.yml ps

echo "=== Rollback complete ==="
