#!/bin/bash
# Kolonie AI — a service with a primary gateway also receives the fallback pair (#257)
#
# Usage: ./scripts/check-gateway-fallback.sh
#
# `kolonie-platform#1695` made OpenRouter the second gateway, configured like the
# first. Compose never passed the names, so production cannot fall back even
# though the process would. Same shape as `#131`: the code was correct and the
# four names reached no runner.
#
# A service that already receives `LLM_GATEWAY_BASE_URL` and a per-service
# `LLM_GATEWAY_API_KEY_*` must also receive `LLM_GATEWAY_FALLBACK_BASE_URL` and
# `LLM_GATEWAY_FALLBACK_API_KEY_<SERVICE>`. An unconfigured half stays empty and
# means "no fallback", which is today's behaviour, not a startup failure.
#
# Services that only see the base URL (the api, which redacts it) are not in
# this set. Doctor-runner has no primary key and is not given one here.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE="$ROOT/docker-compose.yml"
EXAMPLE="$ROOT/.env.example"

[ -f "$COMPOSE" ] || { echo "no docker-compose.yml at $COMPOSE" >&2; exit 2; }
[ -f "$EXAMPLE" ] || { echo "no .env.example at $EXAMPLE" >&2; exit 2; }

# Per service: environment keys that compose assigns (the left-hand names the
# container sees). Six-space `NAME:` lines under each service block.
mapfile -t rows < <(awk '
  /^  [a-z][a-z0-9-]*:$/ { svc = $1; sub(/:$/, "", svc); in_env = 0; next }
  /^    environment:[[:space:]]*$/ { in_env = 1; next }
  /^    [a-z]/ { in_env = 0; next }
  in_env && /^      [A-Z_][A-Z0-9_]*:/ {
    key = $1
    sub(/:$/, "", key)
    print svc "\t" key
  }
' "$COMPOSE")

services=$(printf '%s\n' "${rows[@]}" | cut -f1 | sort -u)

status=0
required_host=()

while IFS= read -r svc; do
  [ -n "$svc" ] || continue
  keys=$(printf '%s\n' "${rows[@]}" | awk -F '\t' -v s="$svc" '$1 == s { print $2 }')
  printf '%s\n' "$keys" | grep -qx 'LLM_GATEWAY_BASE_URL' || continue
  primary=$(printf '%s\n' "$keys" | grep -E '^LLM_GATEWAY_API_KEY_[A-Z0-9_]+$' || true)
  [ -n "$primary" ] || continue

  suffixes=$(printf '%s\n' "$primary" | sed 's/^LLM_GATEWAY_API_KEY_//')
  while IFS= read -r suffix; do
    [ -n "$suffix" ] || continue
    fallback_key="LLM_GATEWAY_FALLBACK_API_KEY_${suffix}"
    missing=()
    printf '%s\n' "$keys" | grep -qx 'LLM_GATEWAY_FALLBACK_BASE_URL' || missing+=("LLM_GATEWAY_FALLBACK_BASE_URL")
    printf '%s\n' "$keys" | grep -qx "$fallback_key" || missing+=("$fallback_key")
    required_host+=("LLM_GATEWAY_FALLBACK_BASE_URL" "$fallback_key")
    if [ ${#missing[@]} -gt 0 ]; then
      echo "$svc receives LLM_GATEWAY_BASE_URL and LLM_GATEWAY_API_KEY_${suffix} but not:" >&2
      printf '  %s\n' "${missing[@]}" >&2
      status=1
    fi
  done <<< "$suffixes"
done <<< "$services"

documented=$(grep -oE '^#?[A-Za-z_][A-Za-z0-9_]*=' "$EXAMPLE" | tr -d '#=')
if [ ${#required_host[@]} -gt 0 ]; then
  unique_host=$(printf '%s\n' "${required_host[@]}" | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$documented" | grep -qx "$name" && continue
    echo ".env.example does not list $name, which compose interpolates" >&2
    status=1
  done <<< "$unique_host"
fi

if [ "$status" -eq 0 ]; then
  echo "every service with a primary gateway also receives the fallback pair"
fi
exit "$status"
