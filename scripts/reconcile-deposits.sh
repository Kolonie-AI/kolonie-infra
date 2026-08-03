#!/bin/bash
# Kolonie AI — credit the deposits the webhook never delivered (kolonie-infra#72)
#
# **A missed webhook delivery is a delay only if something reconciles**, and
# until this existed nothing did: `reconcileDeposits` had been in
# `kolonie-platform` since #219 with no caller at all. This is the caller.
#
# It does no work of its own. Everything — the database, the deposit addresses,
# the sealing key, the RPC endpoint — is already held by the API container, and
# a second process with the same credentials would be a second place to leak
# them. So this asks the API to run its own pass and prints what came back.
#
# ## Why it runs on the host and not inside the API
#
# The alternative was a scheduler inside `apps/api`. That would put a second
# thing that fires on a clock inside a process whose job is to answer requests,
# and it would fire once per replica the day there is more than one. The backup
# already works this way (`kolonie-backup.timer`) and the unit files live here.
#
# ## Idempotent, and that is the property that lets a timer own it
#
# The credit is keyed on the transaction signature by a unique index — the same
# index that makes a webhook redelivery safe. A pass that overlaps the webhook,
# or a second pass started by hand while the timer's is still running, credits
# nothing twice.
#
# Usage, on the deploy host:
#
#   ./scripts/reconcile-deposits.sh
#
# Exit codes: 0 the pass ran, 2 it could not be started, 3 the API refused.

set -euo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
CONTAINER="${API_CONTAINER:-kolonie-api}"
ENV_FILE="${KOLONIE_ENV_FILE:-$DEPLOY_DIR/.env}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: no container named $CONTAINER on this host."
    echo "  This asks the running API to reconcile; it has to run where the API lives."
    exit 2
fi

# The webhook secret authenticates this call, because the route is the webhook's
# neighbour and shares its guard: one power, one secret. Read from the compose
# .env rather than passed, so it never reaches a process listing or a shell
# history — `ps` shows every argument of every process to every user on the box.
if [[ ! -r "$ENV_FILE" ]]; then
    echo "FAIL: cannot read $ENV_FILE, which is where DEPOSIT_WEBHOOK_SECRET lives."
    exit 2
fi

SECRET="$(grep -E '^DEPOSIT_WEBHOOK_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2-)"

if [[ -z "$SECRET" ]]; then
    # Not a failure. Without the secret the route is not mounted at all, which
    # is a deliberate state of the deployment rather than a fault — and a timer
    # that failed hourly against a deliberate configuration would train whoever
    # reads the journal to ignore it.
    echo "skipped: DEPOSIT_WEBHOOK_SECRET is unset, so the deposit routes are not mounted."
    exit 0
fi

# `curl` from inside the container: the API is on the Docker network and
# publishes no port to the host, which is how it should stay. `-s` with
# `--fail-with-body` so a refusal prints its reason instead of an empty line.
RESPONSE="$(docker exec -e SECRET="$SECRET" "$CONTAINER" \
    curl -sS --fail-with-body --max-time 300 \
    -X POST \
    -H "Authorization: $SECRET" \
    http://127.0.0.1:3000/v1/deposits/reconcile 2>&1)" || {
    echo "FAIL: the API refused or could not answer the reconciliation."
    echo "  $RESPONSE"
    exit 3
}

# Printed as one line so `journalctl -u kolonie-reconcile` reads as a history of
# passes. `recovered` is the number that matters: it is how many deposits the
# webhook missed, and a non-zero one that keeps recurring says the webhook is
# not working rather than that this script is.
echo "reconciled: $RESPONSE"
