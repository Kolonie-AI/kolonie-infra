#!/bin/bash
# Kolonie AI — Deployment Script
# Called by GitHub Actions after image build

set -euo pipefail

DEPLOY_DIR="/opt/kolonie"
BACKUP_DIR="/opt/kolonie/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SERVICE=${1:-all}
API_IMAGE="ghcr.io/kolonie-ai/kolonie-api:latest"
WEBSITE_IMAGE="ghcr.io/kolonie-ai/kolonie-website:latest"

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
#
# Each profile is probed on its own. One unreachable image must never stop the
# others from deploying: `docker compose pull` fails the whole command for a
# single missing image, and that is exactly how the unbuilt website image took
# api and verifier-runner down with it (#1).
detect_profile() {
    PROFILE_ARGS=()

    if docker manifest inspect "$API_IMAGE" >/dev/null 2>&1; then
        PROFILE_ARGS+=(--profile full)
        log "Application images reachable — including --profile full"
    else
        log "WARN: $API_IMAGE is not reachable."
        log "WARN: api.kolonie.ai, academy.kolonie.ai and mcp.kolonie.ai will answer 502."
    fi

    if docker manifest inspect "$WEBSITE_IMAGE" >/dev/null 2>&1; then
        PROFILE_ARGS+=(--profile website)
        log "Website image reachable — including --profile website"
    else
        log "WARN: $WEBSITE_IMAGE is not reachable. kolonie.ai will answer 502."
        log "WARN: the image builds in kolonie-website; kolonie-infra may still"
        log "WARN: need read access to the package under Manage Actions access."
    fi

    if [ ${#PROFILE_ARGS[@]} -eq 0 ]; then
        log "WARN: no application images reachable — deploying infrastructure only."
    fi
}

# Snapshot the current state.
#
# Must run *after* detect_profile(): `config` without the profile arguments
# silently omits every profiled service, and a snapshot missing api,
# verifier-runner and website is worse than no snapshot at all — see rollback().
backup() {
    log "Creating backup..."
    mkdir -p "$BACKUP_DIR"
    docker compose -f "$DEPLOY_DIR/docker-compose.yml" ps --format json > "$BACKUP_DIR/ps_${TIMESTAMP}.json" 2>/dev/null || true
    docker compose "${PROFILE_ARGS[@]}" -f "$DEPLOY_DIR/docker-compose.yml" config > "$DEPLOY_DIR/docker-compose.last.yml" 2>/dev/null || true
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

    local services
    if [ "$SERVICE" = "all" ]; then
        # Only the services that were actually deployed. Listing every service
        # in the file would warn about profiled containers that were never
        # started, which reads like a fault and is not one.
        services=$(cd "$DEPLOY_DIR" && docker compose "${PROFILE_ARGS[@]}" config --services)
    else
        services="$SERVICE"
    fi

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
# Note what this can and cannot do. It restores the previous *configuration*.
# It cannot restore the previous *images*, because they are tagged `:latest` and
# the old digest is not recorded anywhere. Rolling back to a known-good build
# needs immutable tags — filed as kolonie-infra#12.
rollback() {
    log "Rolling back..."
    cd "$DEPLOY_DIR"
    if [ -f "docker-compose.last.yml" ]; then
        docker compose -f docker-compose.last.yml up -d 2>&1 || {
            log "ERROR: Rollback also failed! Manual intervention needed."
            exit 2
        }
        log "Rollback completed — previous configuration restored, images unchanged"
    else
        log "WARN: No previous compose config found; leaving containers as they are"
    fi
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
deploy
healthcheck
log "=== Deployment completed ==="
