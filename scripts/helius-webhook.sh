#!/bin/bash
# Kolonie AI — tell Helius which deposit addresses to watch (kolonie-infra#73)
#
# `kolonie-platform#219` built the route that turns *a transfer happened* into a
# balance, and `#321` made it accept the shape a real sender posts. Neither of
# them makes a sender exist. This is the sender: it points a Helius enhanced
# webhook at `POST /v1/deposits/webhook` and keeps the watched address list equal
# to what is in `deposit_addresses`.
#
# ## Why this is a sync and not a setup step
#
# The obvious version of this issue is *create a webhook once, from the
# dashboard*. It is wrong for a reason the issue names itself: **one deposit
# address per identity, created on first ask**, so the set grows every time a
# sponsor asks where to send. A webhook configured against today's addresses
# stops covering tomorrow's, silently, and the failure is a deposit nobody
# credits promptly — which is the failure the webhook exists to prevent.
#
# So the address list is derived, every run, from the database. Running this
# twice in a row is a no-op; running it after a new address appears is what
# makes the webhook cover it. `kolonie-reconcile.timer` covers the gap in between
# (#72), which is why the gap is tolerable rather than urgent.
#
# ## Measured against the Helius API on 2026-08-05, not assumed
#
# - **An empty address list is refused**, on create and on edit alike:
#   `400 {"message":["At least one account address is required"]}`. So *watch
#   nothing* cannot be expressed as a webhook with no addresses; it is expressed
#   by there being no webhook, which is what this script does.
# - `transactionTypes: ["Any"]` is accepted and comes back normalised to `ANY`.
# - `authHeader` round-trips: what is sent is what Helius later presents in the
#   `Authorization` header, byte for byte. `webhookAuthorised` compares the whole
#   header against the secret with no `Bearer ` prefix, so the two agree.
#
# ## Why `Any` rather than `TRANSFER`
#
# The reader is built to tolerate a chatty sender — `claimsInDelivery` skips a
# transaction with no `tokenTransfers` and calls it *not an error*, and the route
# drops addresses the Colony never generated before it reads anything from the
# chain. So the cost of a transaction type nobody wanted is one ignored delivery.
#
# The cost in the other direction is a deposit that is never delivered because
# Helius classified it as something other than a transfer, and that one is
# invisible until a sponsor asks where their money went. Given an asymmetry that
# large, the sender is told to be generous and the reader stays strict.
#
# ## What it never prints
#
# The API key, the webhook secret, and the addresses. The first two for the
# obvious reason; the addresses because a deposit address identifies a sponsor,
# and `journalctl` is readable by anyone who can read the host. Counts only —
# which is also all an operator needs to answer *did it change anything*.
#
# Usage, on the deploy host:
#
#   ./scripts/helius-webhook.sh              # sync
#   ./scripts/helius-webhook.sh --dry-run    # say what it would do, change nothing
#
# Exit codes: 0 the sync ran (or was deliberately skipped), 2 it could not be
# started, 3 Helius refused.

set -euo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
ENV_FILE="${KOLONIE_ENV_FILE:-$DEPLOY_DIR/.env}"
DB_CONTAINER="${DB_CONTAINER:-kolonie-postgres}"
HELIUS_API="${HELIUS_API:-https://api.helius.xyz/v0/webhooks}"

DRY_RUN=no
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=yes
elif [[ $# -gt 0 ]]; then
    echo "FAIL: unknown argument '$1'. Usage: $0 [--dry-run]"
    exit 2
fi

for tool in curl jq docker; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: $tool is not on this host, and this script cannot work without it."
        exit 2
    fi
done

if [[ ! -r "$ENV_FILE" ]]; then
    echo "FAIL: cannot read $ENV_FILE, which is where the key and the secret live."
    exit 2
fi

# Read from the file rather than taken as arguments, for the reason
# `reconcile-deposits.sh` gives: `ps` shows every argument of every process to
# every user on the box.
#
# `|| true` on each, and it is load-bearing rather than defensive: `pipefail`
# makes a pipeline carry grep's exit status, and grep answers 1 when it matches
# nothing — which is exactly the case the next branches exist to handle.
read_env() {
    grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true
}

API_KEY="$(read_env HELIUS_API_KEY)"
SECRET="$(read_env DEPOSIT_WEBHOOK_SECRET)"
API_URL="$(read_env API_URL)"

if [[ -z "$SECRET" ]]; then
    # Not a failure, and the same judgement `reconcile-deposits.sh` makes about
    # the same variable: without the secret the route is **not mounted at all**,
    # so a webhook pointed at it would post into a 404 forever. A deliberate
    # configuration must not report as a fault, or whoever reads the journal
    # learns to ignore it.
    echo "skipped: DEPOSIT_WEBHOOK_SECRET is unset, so the deposit routes are not mounted."
    exit 0
fi

if [[ -z "$API_KEY" ]]; then
    echo "FAIL: HELIUS_API_KEY is unset in $ENV_FILE, so nothing can be told to watch anything."
    echo "  It is regenerable from the Helius dashboard — unlike DEPOSIT_SEALING_KEY two"
    echo "  entries above it, which must never be rotated while a deposit address exists."
    exit 2
fi

if [[ -z "$API_URL" ]]; then
    echo "FAIL: API_URL is unset in $ENV_FILE, so there is no address to deliver to."
    exit 2
fi

WEBHOOK_URL="${API_URL%/}/v1/deposits/webhook"

if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: no container named $DB_CONTAINER on this host."
    echo "  The watched list is derived from deposit_addresses; it has to run where the database is."
    exit 2
fi

PG_USER="$(read_env POSTGRES_USER)"
PG_DB="$(read_env POSTGRES_DB)"

# `-A -t` for unaligned, tuple-only output: one address per line and nothing
# else, so the sort below sees addresses rather than table decoration.
WANTED="$(docker exec "$DB_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -A -t \
    -c 'select address from deposit_addresses order by address' 2>&1)" || {
    echo "FAIL: could not read deposit_addresses."
    echo "  $WANTED"
    exit 2
}

WANTED="$(printf '%s\n' "$WANTED" | sed '/^$/d')"
WANTED_COUNT=0
[[ -n "$WANTED" ]] && WANTED_COUNT="$(printf '%s\n' "$WANTED" | wc -l | tr -d ' ')"

EXISTING="$(curl -sS --fail-with-body --max-time 60 "${HELIUS_API}?api-key=${API_KEY}" 2>&1)" || {
    echo "FAIL: Helius would not list the webhooks."
    # The key is in the URL, so curl's own error text can carry it. Print the
    # body only, which is Helius's message and holds no credential.
    echo "  ${EXISTING//$API_KEY/<api-key>}"
    exit 3
}

# Identified by the URL it delivers to, and deliberately not by an id kept in a
# file. Nothing on this host has a place to keep an id that survives a rebuild,
# and the delivery URL is the identity as far as the Colony is concerned: two
# webhooks pointing at this route would be two deliveries of every deposit.
WEBHOOK_ID="$(printf '%s' "$EXISTING" | jq -r --arg u "$WEBHOOK_URL" \
    'map(select(.webhookURL == $u)) | .[0].webhookID // empty')"

CURRENT_COUNT=0
if [[ -n "$WEBHOOK_ID" ]]; then
    CURRENT="$(printf '%s' "$EXISTING" | jq -r --arg u "$WEBHOOK_URL" \
        'map(select(.webhookURL == $u)) | .[0].accountAddresses[]?' | sort)"
    [[ -n "$CURRENT" ]] && CURRENT_COUNT="$(printf '%s\n' "$CURRENT" | wc -l | tr -d ' ')"
else
    CURRENT=""
fi

WANTED_SORTED="$(printf '%s' "$WANTED" | sort)"

# ---------------------------------------------------------------------------
# Nothing to watch.
# ---------------------------------------------------------------------------
if [[ "$WANTED_COUNT" -eq 0 ]]; then
    if [[ -z "$WEBHOOK_ID" ]]; then
        echo "nothing to watch: no deposit address exists yet, and no webhook is configured."
        echo "  Helius refuses a webhook with an empty address list, so this is the correct"
        echo "  state rather than a missing step. Run this again when the first sponsor asks"
        echo "  where to send."
        exit 0
    fi

    # A webhook watching addresses that no longer exist is not harmless enough to
    # leave: the rows go when an agent is erased, and continuing to ask Helius to
    # report on an erased citizen's address is exactly what `governance/erasure.md`
    # says the Colony stops doing.
    echo "removing: the webhook watches $CURRENT_COUNT address(es) and none remain in the database."
    if [[ "$DRY_RUN" == yes ]]; then
        echo "dry-run: would DELETE the webhook."
        exit 0
    fi
    RESPONSE="$(curl -sS --fail-with-body --max-time 60 -X DELETE \
        "${HELIUS_API}/${WEBHOOK_ID}?api-key=${API_KEY}" 2>&1)" || {
        echo "FAIL: Helius refused the delete."
        echo "  ${RESPONSE//$API_KEY/<api-key>}"
        exit 3
    }
    echo "removed: no webhook is configured."
    exit 0
fi

# ---------------------------------------------------------------------------
# Already correct.
# ---------------------------------------------------------------------------
if [[ -n "$WEBHOOK_ID" && "$CURRENT" == "$WANTED_SORTED" ]]; then
    echo "unchanged: the webhook watches all $WANTED_COUNT deposit address(es)."
    exit 0
fi

ADDED=0
REMOVED=0
if [[ -n "$WEBHOOK_ID" ]]; then
    ADDED="$(comm -13 <(printf '%s\n' "$CURRENT") <(printf '%s\n' "$WANTED_SORTED") | sed '/^$/d' | wc -l | tr -d ' ')"
    REMOVED="$(comm -23 <(printf '%s\n' "$CURRENT") <(printf '%s\n' "$WANTED_SORTED") | sed '/^$/d' | wc -l | tr -d ' ')"
fi

# `-c`, so the body is one line. It is never read by a person, and a multi-line
# one turns any log of what was sent into something a `grep` cannot follow.
BODY="$(jq -nc \
    --arg url "$WEBHOOK_URL" \
    --arg auth "$SECRET" \
    --argjson addresses "$(printf '%s' "$WANTED_SORTED" | jq -Rs 'split("\n") | map(select(length > 0))')" \
    '{
        webhookURL: $url,
        transactionTypes: ["Any"],
        accountAddresses: $addresses,
        webhookType: "enhanced",
        authHeader: $auth
    }')"

if [[ -z "$WEBHOOK_ID" ]]; then
    echo "creating: a webhook on $WANTED_COUNT deposit address(es), delivering to $WEBHOOK_URL"
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
    echo "created: webhook $ID watching $WANTED_COUNT address(es)."
    exit 0
fi

echo "updating: $ADDED to add, $REMOVED to drop, $WANTED_COUNT watched after this."
if [[ "$DRY_RUN" == yes ]]; then
    echo "dry-run: would PUT the edit."
    exit 0
fi

# The whole set every time, not a delta. Helius's edit replaces the list, and a
# script that computed a delta would have two ideas of what is watched — the
# database's and its own. One of them would eventually be wrong and nothing
# would say which.
RESPONSE="$(curl -sS --fail-with-body --max-time 60 -X PUT \
    "${HELIUS_API}/${WEBHOOK_ID}?api-key=${API_KEY}" \
    -H 'Content-Type: application/json' -d "$BODY" 2>&1)" || {
    echo "FAIL: Helius refused the edit."
    echo "  ${RESPONSE//$API_KEY/<api-key>}"
    exit 3
}

NOW="$(printf '%s' "$RESPONSE" | jq -r '.accountAddresses | length')"
echo "updated: webhook $WEBHOOK_ID watching $NOW address(es)."
