#!/bin/bash
# Kolonie AI — which commit each running container was built from (#44)
#
# Answers, from the host and with no registry access, the question that took
# three steps and two systems on 2026-07-30: **which commit is this container
# running?** A deploy fan-out had left `verifier-runner` on an older image than
# the commit that triggered it, and confirming that meant listing GHCR package
# versions and matching digests — the wrong shape of answer during a partial
# deploy, when somebody has to find out per service what shipped and what did
# not, quickly.
#
# The images carry `org.opencontainers.image.revision` since kolonie-platform#75.
# This script reads it. That is the whole of it.
#
# Output, one tab-separated row per service:
#
#   SERVICE  REVISION  IMAGE
#
# REVISION is the commit sha, or `-` when the container carries no such label —
# which is what every image built before #75 looks like, and what a container
# that is not running looks like. The caller has to tell those apart from a
# revision it simply does not recognise, so this script never guesses: it reports
# what it read and nothing else.
#
# Usage:
#   ./scripts/deployed-revision.sh
#
# Needs a Docker daemon and nothing else. No secrets, no host names, no registry.

set -uo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"

# The services whose images this organisation builds. Postgres and Traefik are
# upstream images and carry somebody else's revision, which would be noise.
SERVICES=(api verifier-runner moderation-runner website)

docker_cmd() {
    # Same reasoning as health-report.sh, including the `</dev/null`: without it
    # the docker CLI eats the stdin of the calling loop and the report covers one
    # service while looking complete.
    if docker info >/dev/null 2>&1; then
        docker "$@" </dev/null
    else
        sudo -n docker "$@" </dev/null
    fi
}

for svc in "${SERVICES[@]}"; do
    container="kolonie-${svc}"

    # Two separate reads rather than one template with both fields: a container
    # that is absent must still produce a row, and merging them means one missing
    # container drops a service out of the report entirely.
    revision=$(docker_cmd inspect "$container" \
        --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null)
    image=$(docker_cmd inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)

    # Docker 29 renders an absent label as an empty string; older versions render
    # `<no value>`, and an image with no labels at all can render `map[]`. None of
    # those is a commit, and all three mean the same thing to the caller.
    case "$revision" in "<no value>"|"map[]"|"") revision="-" ;; esac
    [ -z "$image" ] && image="-"

    printf '%s\t%s\t%s\n' "$svc" "$revision" "$image"
done

exit 0
