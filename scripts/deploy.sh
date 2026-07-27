#!/bin/bash
# Kolonie AI — Deployment Script
# Called by GitHub Actions after image build

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
BACKUP_DIR="/opt/kolonie/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SERVICE=${1:-all}
API_IMAGE="ghcr.io/kolonie-ai/kolonie-api:latest"

# Filled in by detect_profile(). Empty means infrastructure only.
PROFILE_ARGS=()

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
detect_profile() {
    if docker manifest inspect "$API_IMAGE" >/dev/null 2>&1; then
        PROFILE_ARGS=(--profile full)
        log "Application images reachable — deploying with --profile full"
    else
        PROFILE_ARGS=()
        log "WARN: $API_IMAGE is not reachable. Deploying infrastructure only."
        log "WARN: kolonie.ai, api.kolonie.ai, academy.kolonie.ai and mcp.kolonie.ai"
        log "WARN: will answer 502 until this is resolved — see kolonie-infra#1."
    fi
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
    if [ "$SERVICE" = "all" ]; then
        docker compose "${PROFILE_ARGS[@]}" pull 2>&1 || {
            log "ERROR: Image pull failed"
            exit 1
        }
    else
        docker compose "${PROFILE_ARGS[@]}" pull "$SERVICE" 2>&1 || {
            log "ERROR: Image pull failed"
            exit 1
        }
    fi
}

# Deploy
deploy() {
    log "Deploying service: $SERVICE"
    cd "$DEPLOY_DIR"
    if [ "$SERVICE" = "all" ]; then
        docker compose "${PROFILE_ARGS[@]}" up -d --remove-orphans 2>&1 || {
            log "ERROR: Deployment failed"
            rollback
            exit 1
        }
    else
        docker compose "${PROFILE_ARGS[@]}" up -d --remove-orphans "$SERVICE" 2>&1 || {
            log "ERROR: Deployment failed"
            rollback
            exit 1
        }
    fi
}

# Health check
healthcheck() {
    log "Running health checks..."
    sleep 10

    local services
    if [ "$SERVICE" = "all" ]; then
        # Only the services that were actually deployed. Listing every service
        # in the file would warn about profiled containers that were never
        # started, which reads like a fault and is not one.
        services=$(cd "$DEPLOY_DIR" && docker compose "${PROFILE_ARGS[@]}" config --services)
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
trap ghcr_logout EXIT
backup
ghcr_login
detect_profile
pull
deploy
healthcheck
log "=== Deployment completed ==="
