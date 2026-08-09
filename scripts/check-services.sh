#!/bin/bash
# Kolonie AI — does scripts/services.sh still name every service? (#107)
#
# Usage: ./scripts/check-services.sh
#
# `services.sh` is the one list the drift check, the pin check and the deploy
# read. A service added to `docker-compose.yml` and not added there is a service
# every one of those monitors is silently blind to — which is not a hypothetical:
# `deployed-revision.sh` carried a four-name copy while compose had six, and on
# 2026-08-09 `badge-runner` failed thirteen consecutive deploys while the drift
# check reported every service it could see as current.
#
# So this asserts the list against the file it can drift from, and it fails the
# build rather than filing anything. A monitor whose blind spot is caught by a
# monitor is a chain with the same weak link twice.
#
# ## What counts as a service this organisation builds
#
# One whose image is `ghcr.io/kolonie-ai/...` in `docker-compose.yml`. Traefik,
# Postgres, Loki, Promtail and pgAdmin are upstream images pinned to somebody
# else's version, so there is no record of intent for them to drift from and they
# are correctly absent from `services.sh`. Deriving the expected set from the
# registry prefix rather than from a second hand-written list is what keeps this
# check from being the third copy of the thing it is checking.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE="$ROOT/docker-compose.yml"

# shellcheck source=scripts/services.sh
. "$ROOT/scripts/services.sh"

[ -f "$COMPOSE" ] || { echo "no docker-compose.yml at $COMPOSE" >&2; exit 2; }

# Every compose service whose image comes from this organisation's registry.
# `image:` sits two lines below the service key at most, so the block is read
# rather than the whole file grepped: a match anywhere would pick up a comment.
expected=$(awk '
    /^  [a-z][a-z0-9-]*:$/ { svc = $1; sub(/:$/, "", svc); next }
    /^    image:/ && svc != "" && /ghcr\.io\/kolonie-ai\// { print svc; svc = "" }
' "$COMPOSE" | sort)

listed=$(printf '%s\n' "${KOLONIE_SERVICES[@]}" | sort)

missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed"))
extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed"))

status=0

if [ -n "$missing" ]; then
    echo "docker-compose.yml builds these and scripts/services.sh does not name them:" >&2
    printf '  %s\n' $missing >&2
    echo "Every monitor that reads that list is blind to them until they are added." >&2
    status=1
fi

if [ -n "$extra" ]; then
    echo "scripts/services.sh names these and docker-compose.yml does not build them:" >&2
    printf '  %s\n' $extra >&2
    echo "A monitor reporting on a service that does not exist reads as a broken monitor." >&2
    status=1
fi

# The second list has to agree with the first, or `pin-report.sh` and
# `deployed-revision.sh` cover different sets again by a different route.
mapped=$(printf '%s\n' "${KOLONIE_SERVICE_IMAGES[@]}" | cut -d: -f1 | sort)
if [ "$mapped" != "$listed" ]; then
    echo "KOLONIE_SERVICES and KOLONIE_SERVICE_IMAGES name different services." >&2
    diff <(printf '%s\n' "$listed") <(printf '%s\n' "$mapped") >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "scripts/services.sh names every service this organisation builds ($(printf '%s\n' "${KOLONIE_SERVICES[@]}" | wc -l | tr -d ' ') of them)."
fi

exit "$status"
