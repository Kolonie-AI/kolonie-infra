#!/bin/bash
# Kolonie AI — Health Check Script
# Quick check if all services are responding

set -euo pipefail

DOMAINS=("kolonie.ai" "api.kolonie.ai" "academy.kolonie.ai")
FAILED=0

for domain in "${DOMAINS[@]}"; do
    status=$(curl -s -o /dev/null -w "%{http_code}" "https://$domain/health" --max-time 10 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
        echo "OK: $domain ($status)"
    else
        echo "FAIL: $domain ($status)"
        FAILED=$((FAILED + 1))
    fi
done

exit $FAILED
