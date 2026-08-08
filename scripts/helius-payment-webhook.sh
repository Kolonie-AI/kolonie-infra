#!/bin/bash
# Kolonie AI — tell Helius to watch the Colony's own wallet (kolonie-platform#503)
#
# Under D-106 the Colony holds one wallet and a sponsor pays into it from its
# own. This points a Helius enhanced webhook at `POST /v1/payments/webhook` for
# that one address.
#
# ## Why this is not a sync, and the deposit webhook next door was
#
# The deposit webhook watched a set that grew every time a sponsor asked where to
# send, so it was derived from the database on every run — and it went with the
# module it served (`kolonie-platform#506`, `kolonie-infra#94`). This one watches
# **exactly one address**, fixed at deploy time in `PAYOUT_WALLET_ADDRESS`. There
# is nothing to keep in step, so this is idempotent rather than periodic: run it
# once, run it again after a wallet rotation, and never on a timer.
#
# `kolonie-payments-reconcile.timer` is what covers a webhook that stops
# delivering — and that is not a hypothetical here. kolonie-infra#73 records this
# provider's webhook registered, correctly authenticated and silent.
#
# ## What it never prints
#
# The API key and the webhook secret. The wallet address **is** printed: it is
# the Colony's own, it is on chain, and an operator running this needs to see
# which address was configured. A sponsor's address would not be — that
# identifies a citizen — which is why the deposit sync printed counts only.
#
# Usage, on the deploy host:
#
#   ./scripts/helius-payment-webhook.sh              # configure
#   ./scripts/helius-payment-webhook.sh --dry-run    # say what it would do
#
# Exit codes: 0 configured or already correct, 2 could not start, 3 Helius refused.

set -euo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
ENV_FILE="${KOLONIE_ENV_FILE:-$DEPLOY_DIR/.env}"
HELIUS_API="${HELIUS_API:-https://api.helius.xyz/v0/webhooks}"

DRY_RUN=no
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=yes
elif [[ $# -gt 0 ]]; then
    echo "FAIL: unknown argument '$1'. Usage: $0 [--dry-run]"
    exit 2
fi

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: $tool is not on this host, and this script cannot work without it."
        exit 2
    fi
done

if [[ ! -r "$ENV_FILE" ]]; then
    echo "FAIL: cannot read $ENV_FILE, which is where the key, the secret and the wallet live."
    exit 2
fi

# Read from the file rather than taken as arguments: `ps` shows every argument of
# every process to every user on the box. `|| true` because grep answers 1 on no
# match, which is the case the branches below handle.
read_env() {
    grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true
}

API_KEY="$(read_env HELIUS_API_KEY)"
SECRET="$(read_env DEPOSIT_WEBHOOK_SECRET)"
API_URL="$(read_env API_URL)"
WALLET="$(read_env PAYOUT_WALLET_ADDRESS)"

if [[ -z "$SECRET" ]]; then
    echo "skipped: DEPOSIT_WEBHOOK_SECRET is unset, so the payment routes are not mounted."
    exit 0
fi

if [[ -z "$WALLET" ]]; then
    # Not a failure for the same reason: without a wallet the API mounts no
    # payment routes at all, and a webhook pointed at one would post into a 404.
    echo "skipped: PAYOUT_WALLET_ADDRESS is unset, so this deployment takes no payments."
    exit 0
fi

if [[ -z "$API_KEY" ]]; then
    echo "FAIL: HELIUS_API_KEY is unset in $ENV_FILE, so nothing can be told to watch anything."
    exit 2
fi

if [[ -z "$API_URL" ]]; then
    echo "FAIL: API_URL is unset in $ENV_FILE, so there is no address to deliver to."
    exit 2
fi

WEBHOOK_URL="${API_URL%/}/v1/payments/webhook"

EXISTING="$(curl -sS --fail-with-body --max-time 60 "${HELIUS_API}?api-key=${API_KEY}" 2>&1)" || {
    echo "FAIL: Helius would not list the webhooks."
    # The key is in the URL, so curl's own error text can carry it.
    echo "  ${EXISTING//$API_KEY/<api-key>}"
    exit 3
}

# Identified by the URL it delivers to, exactly as the deposit webhook is: two
# webhooks pointing at this route would be two deliveries of every payment, and
# nothing on this host has a place to keep an id that survives a rebuild.
WEBHOOK_ID="$(printf '%s' "$EXISTING" | jq -r --arg u "$WEBHOOK_URL" \
    'map(select(.webhookURL == $u)) | .[0].webhookID // empty')"
CURRENT="$(printf '%s' "$EXISTING" | jq -r --arg u "$WEBHOOK_URL" \
    'map(select(.webhookURL == $u)) | .[0].accountAddresses // [] | join(",")')"

if [[ -n "$WEBHOOK_ID" && "$CURRENT" == "$WALLET" ]]; then
    echo "unchanged: webhook $WEBHOOK_ID watches $WALLET."
    exit 0
fi

# `transactionTypes: ["Any"]` for the reason the deposit webhook gives at length:
# the cost of a delivery nobody wanted is one ignored line, and the cost of a
# payment Helius classified as something other than a transfer is a quest that
# never goes live until the hourly pass notices.
BODY="$(jq -nc --arg url "$WEBHOOK_URL" --arg auth "$SECRET" --arg address "$WALLET" \
    '{
        webhookURL: $url,
        transactionTypes: ["Any"],
        accountAddresses: [$address],
        webhookType: "enhanced",
        authHeader: $auth
    }')"

if [[ -z "$WEBHOOK_ID" ]]; then
    echo "creating: a webhook on $WALLET, delivering to $WEBHOOK_URL"
    if [[ "$DRY_RUN" == yes ]]; then
        echo "dry-run: would POST the create."
        exit 0
    fi
    RESPONSE="$(curl -sS --fail-with-body --max-time 60 -X POST \
        "${HELIUS_API}?api-key=${API_KEY}" \
        -H 'Content-Type: application/json' -d "$BODY" 2>&1)" || {
        echo "FAIL: Helius refused the create."
        echo "  ${RESPONSE//$API_KEY/<api-key>}"
        exit 3
    }
    ID="$(printf '%s' "$RESPONSE" | jq -r '.webhookID // "?"')"
    echo "created: webhook $ID watching $WALLET."
    exit 0
fi

echo "updating: webhook $WEBHOOK_ID watched [$CURRENT] and should watch $WALLET."
if [[ "$DRY_RUN" == yes ]]; then
    echo "dry-run: would PUT the edit."
    exit 0
fi

RESPONSE="$(curl -sS --fail-with-body --max-time 60 -X PUT \
    "${HELIUS_API}/${WEBHOOK_ID}?api-key=${API_KEY}" \
    -H 'Content-Type: application/json' -d "$BODY" 2>&1)" || {
    echo "FAIL: Helius refused the edit."
    echo "  ${RESPONSE//$API_KEY/<api-key>}"
    exit 3
}

echo "updated: webhook $WEBHOOK_ID watching $WALLET."
