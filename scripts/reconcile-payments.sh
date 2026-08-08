#!/bin/bash
# Kolonie AI — recognise the payments the webhook never delivered (kolonie-platform#503)
#
# The Colony holds one wallet, and a sponsor pays a quest invoice into it from
# its own (D-106). This asks the API to re-read that wallet's recent signatures
# and record what it finds — attributed to the citizen that sent it, or
# quarantined with a reason.
#
# ## This is the path that has to be sufficient on its own
#
# The deposit path had a reconciliation next door that was a backstop to a
# webhook that works, and it went with the module (`kolonie-platform#506`,
# `kolonie-infra#94`). This one is not a backstop. kolonie-infra#73 records a Helius webhook
# that was registered, whose `authHeader` was byte-identical to the host's
# secret, and which was never observed delivering anything — so a design in
# which a dead webhook stops payments being recognised is a design that has
# already failed once, on this host, with real money.
#
# `kolonie-platform#503` states it as an acceptance criterion: *"the
# reconciliation alone is sufficient — a dead webhook must not be able to stop
# payments being recognised."* This script is what makes that true.
#
# It does no work of its own. The database, the wallet address and the RPC
# endpoint are all held by the API container, and a second process with the same
# credentials would be a second place to leak them.
#
# ## Idempotent, which is what lets a timer own it
#
# The row is keyed on the transaction signature by a unique index — the same
# index that makes a webhook redelivery safe. A pass overlapping the webhook, or
# a second pass started by hand, records nothing twice.
#
# Usage, on the deploy host:
#
#   ./scripts/reconcile-payments.sh
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

if [[ ! -r "$ENV_FILE" ]]; then
    echo "FAIL: cannot read $ENV_FILE, which is where DEPOSIT_WEBHOOK_SECRET lives."
    exit 2
fi

# The same secret as the deposit routes, and the same reasoning: one power, one
# secret. The name still says *deposit* because the variable is on the host and
# renaming it is a step for `kolonie-platform#506`, which removes the deposit
# path it was named for. What it authenticates is the chain-observation routes.
#
# `|| true` is load-bearing: `pipefail` carries grep's status, and grep answers 1
# when it matches nothing — the case the next branch exists to handle.
SECRET="$(grep -E '^DEPOSIT_WEBHOOK_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"

if [[ -z "$SECRET" ]]; then
    # Not a failure. Without the secret the routes are not mounted at all, which
    # is a deliberate state rather than a fault — and a timer that failed hourly
    # against a deliberate configuration trains whoever reads the journal to
    # ignore it.
    echo "skipped: DEPOSIT_WEBHOOK_SECRET is unset, so the payment routes are not mounted."
    exit 0
fi

# `curl` from inside the container: the API is on the Docker network and
# publishes no port to the host, which is how it should stay.
RESPONSE="$(docker exec -e SECRET="$SECRET" "$CONTAINER" \
    curl -sS --fail-with-body --max-time 300 \
    -X POST \
    -H "Authorization: $SECRET" \
    http://127.0.0.1:3000/v1/payments/reconcile 2>&1)" || {
    echo "FAIL: the API refused or could not answer the reconciliation."
    echo "  $RESPONSE"
    exit 3
}

# The payouts follow in the same pass, and deliberately after the reconciliation:
# money that has just been recognised may be exactly what a payout was waiting
# on (kolonie-platform#505). A failure here does not fail the unit — the
# reconciliation already succeeded, and an obligation left unpaid is retried in
# fifteen minutes with the amount still owed.
PAYOUTS="$(docker exec -e SECRET="$SECRET" "$CONTAINER" \
    curl -sS --fail-with-body --max-time 300 \
    -X POST \
    -H "Authorization: $SECRET" \
    http://127.0.0.1:3000/v1/payouts/run 2>&1)" || PAYOUTS="FAILED: $PAYOUTS"

# One line, so `journalctl -u kolonie-payments-reconcile` reads as a history of
# passes. Two numbers matter: `recovered` is how many arrivals the webhook
# missed — a non-zero one that keeps recurring says the webhook is not working —
# and `quarantined` is money the Colony is holding and cannot give to anybody,
# which somebody has to look at rather than let accumulate.
echo "reconciled: $RESPONSE"

# `floatShort` is the one to read: it means the wallet holds less than the Colony
# owes its citizens, which is the Colony failing to pay rather than a citizen
# failing to be payable.
echo "paid out: $PAYOUTS"
