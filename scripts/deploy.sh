#!/bin/bash
# Kolonie AI — Deployment Script
# Called by GitHub Actions after image build

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
BACKUP_DIR="/opt/kolonie/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SERVICE=${1:-all}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Backup current state
backup() {
    log "Creating backup..."
    mkdir -p "$BACKUP_DIR"
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" ps --format json > "$BACKUP_DIR/ps_${TIMESTAMP}.json" 2>/dev/null || true
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" config > "$DEPLOY_DIR/docker-compose.last.yml" 2>/dev/null || true
}

# Pull new images
pull() {
    log "Pulling latest images..."
    cd "$DEPLOY_DIR"
    docker compose pull "$SERVICE" 2>&1 || {
        log "ERROR: Image pull failed"
        exit 1
    }
}

# Deploy
deploy() {
    log "Deploying service: $SERVICE"
    cd "$DEPLOY_DIR"
    docker compose up -d --remove-orphans "$SERVICE" 2>&1 || {
        log "ERROR: Deployment failed"
        rollback
        exit 1
    }
}

# Health check
healthcheck() {
    log "Running health checks..."
    sleep 10

    local services
    if [ "$SERVICE" = "all" ]; then
        services=$(docker compose -f "$DEPLOY_DIR/docker-compose.yml" config --services)
    else
        services="$SERVICE"
    fi

    for svc in $services; do
        local container="kolonie-${svc}"
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "no-healthcheck")

        if [ "$status" = "unhealthy" ]; then
            log "ERROR: $svc is unhealthy"
            rollback
            exit 1
        elif [ "$status" = "no-healthcheck" ]; then
            log "WARN: $svc has no health check"
        else
            log "OK: $svc ($status)"
        fi
    done
}

# Rollback
rollback() {
    log "Rolling back..."
    cd "$DEPLOY_DIR"
    if [ -f "docker-compose.last.yml" ]; then
        docker compose -f docker-compose.last.yml up -d --remove-orphans 2>&1 || {
            log "ERROR: Rollback also failed! Manual intervention needed."
            exit 2
        }
        log "Rollback completed"
    else
        log "WARN: No previous compose config found for rollback"
    fi
}

# Main
log "=== Deployment started ==="
backup
pull
deploy
healthcheck
log "=== Deployment completed ==="
