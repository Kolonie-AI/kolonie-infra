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
# Three calls in one pass, in this order and for the reasons given at each: the
# reconciliation, the payouts it may have unblocked, and the sweep of what is
# left over as the Colony's fee (kolonie-platform#507).
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
    echo "FAIL: cannot read $ENV_FILE, which is where PAYMENT_WEBHOOK_SECRET lives."
    exit 2
fi

# One power, one secret: this is what authenticates the chain-observation routes.
#
# **Named `PAYMENT_WEBHOOK_SECRET` since `kolonie-infra#95`.** It was
# `DEPOSIT_WEBHOOK_SECRET`, written for a route that went with the deposit module
# (`kolonie-platform#506`) while the secret stayed to guard the payment ones.
#
# `|| true` is load-bearing: `pipefail` carries grep's status, and grep answers 1
# when it matches nothing — the case the next branch exists to handle.
SECRET="$(grep -E '^PAYMENT_WEBHOOK_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"

if [[ -z "$SECRET" ]]; then
    # Not a failure. Without the secret the routes are not mounted at all, which
    # is a deliberate state rather than a fault — and a timer that failed hourly
    # against a deliberate configuration trains whoever reads the journal to
    # ignore it.
    echo "skipped: PAYMENT_WEBHOOK_SECRET is unset, so the payment routes are not mounted."
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

# And the Colony's own share leaves the hot wallet last (kolonie-platform#507).
#
# ## Why it is here and third, rather than on a timer of its own
#
# **Third is the safety property, not a preference.** The sweep takes what is
# left after every citizen has been paid; running it before the payouts, or on an
# independent clock that could land between them, would let it take money a
# payout in the same minute was about to need. The API refuses that anyway — it
# sizes the transfer as balance minus what is owed minus the float — but an
# ordering that relies on a downstream check is an ordering that only works while
# somebody remembers the check.
#
# ## This timer is not the cadence
#
# It fires every fifteen minutes and a fee sweep should not. **How often the
# Colony actually sends is `TREASURY_SWEEP_INTERVAL_MS` in the settings table**
# (D-104), read by the API on every call; until the interval has passed this
# answers `too-soon` and sends nothing. That is deliberate: the cadence is then a
# maintainer's dial rather than a unit file on a host, and changing it needs no
# deploy and no ssh.
#
# ## Why the Colony cannot spend the Treasury
#
# It holds no key for it. `TREASURY_ADDRESS` is an address and there is no
# variable anywhere carrying a secret for it — asserted on the module's exports
# in `apps/api/src/treasury.test.ts`, so a change that reached for one fails a
# test rather than a review.
#
# A failure here does not fail the unit, for the same reason the payouts do not:
# the reconciliation has already succeeded, and an unswept fee is still earned
# and still swept on the next pass.
SWEEP="$(docker exec -e SECRET="$SECRET" "$CONTAINER" \
    curl -sS --fail-with-body --max-time 300 \
    -X POST \
    -H "Authorization: $SECRET" \
    http://127.0.0.1:3000/v1/treasury/sweep 2>&1)" || SWEEP="FAILED: $SWEEP"

# `refusal` is the field to read. `too-soon` and `nothing-earned` are the two
# ordinary answers and mean the arrangement is working. `float-would-not-cover-it`
# means the fee is stuck in the hot wallet because the wallet holds less than the
# Colony owes plus its float — not an error, and not a state to leave alone.
echo "treasury: $SWEEP"
