#!/bin/bash
# Kolonie AI — Cloudflare range drift check (#56)
#
# `traefik/traefik.yml` trusts Cloudflare's published address ranges to have told
# the truth about the client in X-Forwarded-For. A hard-coded list of 22 CIDRs is
# the whole cost of that decision, and the objection to it is that the list goes
# stale — Cloudflare adds a range, requests arrive from it, and Traefik silently
# reverts to writing the edge as the client. Nothing breaks loudly. The next
# container that reads X-Forwarded-For gets a wrong answer and believes it.
#
# So the list is checked rather than trusted to stay right. This script fetches
# both published lists and compares them with what traefik.yml carries.
#
# **Exit status is the point**, in the idiom of scripts/env-drift.sh:
#   0  the file matches what Cloudflare publishes
#   1  they differ — the difference is printed, in both directions
#   2  the lists could not be fetched, which is not the same as drift
#
# The Diagnose VPS workflow runs it without failing the run, deliberately: a
# stale list is a thing to notice, not a reason to break a diagnosis.
#
# It prints CIDRs, which are Cloudflare's own published addresses and not ours.
# Do not extend it to print anything about the origin — the log of a workflow run
# is not a private place (see env-drift.sh, same rule).
#
# Usage:  ./scripts/cloudflare-ranges.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK="$ROOT/traefik/traefik.yml"

V4_URL="https://www.cloudflare.com/ips-v4"
V6_URL="https://www.cloudflare.com/ips-v6"

if [ ! -f "$TRAEFIK" ]; then
    echo "FAIL: $TRAEFIK not found — run this from a kolonie-infra checkout"
    exit 2
fi

# Every CIDR inside the trustedIPs block, and nothing outside it. Anchoring on
# the block rather than grepping the whole file matters: a CIDR in a comment
# elsewhere would otherwise count as configuration.
configured() {
    awk '
        /^ *forwardedHeaders:/ { in_fh = 1; next }
        in_fh && /^ *trustedIPs:/ { in_list = 1; next }
        in_list && /^ *- / {
            gsub(/^ *- *"?/, ""); gsub(/"? *$/, "")
            print; next
        }
        in_list { exit }
    ' "$TRAEFIK" | sort -u
}

# One curl per URL, and this is not fussiness. `curl url1 url2` concatenates the
# two bodies with nothing between them, and neither list ends in a newline — so a
# single call yields `131.0.72.0/222400:cb00::/32`, one line that is neither
# range. The first run of this script reported 21 published ranges against 22
# configured and named the same two CIDRs as both missing and extra, which is
# what that looks like from the outside.
published() {
    local url
    for url in "$V4_URL" "$V6_URL"; do
        curl -fsS --max-time 20 "$url" || return 1
        echo
    done | tr -d '\r' | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sort -u
}

CONFIGURED="$(configured)"
if [ -z "$CONFIGURED" ]; then
    echo "FAIL: no trustedIPs found in traefik/traefik.yml"
    echo "  Either the block was removed — in which case #56 has been reverted and"
    echo "  this check should go with it — or the file's shape changed and the awk"
    echo "  above no longer finds it. Both are worth a human."
    exit 2
fi

PUBLISHED="$(published)"
if [ -z "$PUBLISHED" ]; then
    echo "SKIP: could not fetch $V4_URL / $V6_URL"
    echo "  This is not drift. A network failure and a stale list are different"
    echo "  facts, and reporting the first as the second is how a check stops"
    echo "  being believed."
    exit 2
fi

echo "=== Cloudflare range drift ==="
echo "traefik.yml trusts $(printf '%s\n' "$CONFIGURED" | wc -l | tr -d ' ') ranges"
echo "Cloudflare publishes $(printf '%s\n' "$PUBLISHED" | wc -l | tr -d ' ')"
echo

MISSING="$(comm -13 <(printf '%s\n' "$CONFIGURED") <(printf '%s\n' "$PUBLISHED"))"
EXTRA="$(comm -23 <(printf '%s\n' "$CONFIGURED") <(printf '%s\n' "$PUBLISHED"))"

report() {
    local heading="$1" body="$2"
    echo "$heading"
    if [ -z "$body" ]; then
        echo "  (none)"
    else
        printf '%s\n' "$body" | sed 's/^/  /'
    fi
    echo
}

report "published by Cloudflare, not trusted here — requests from these arrive with X-Forwarded-For rewritten to the edge:" "$MISSING"
report "trusted here, no longer published — a range Cloudflare has given up, and we would still believe a forwarded header from it:" "$EXTRA"

if [ -z "$MISSING" ] && [ -z "$EXTRA" ]; then
    echo "OK — the list matches"
    exit 0
fi

echo "DRIFT — update the trustedIPs block in traefik/traefik.yml and redeploy."
echo "It is static configuration, so it takes a Traefik restart rather than a reload."
exit 1
