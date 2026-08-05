#!/bin/bash
# Rehearse helius-webhook.sh without Helius, a host, or a database (#73).
#
# Usage: ./scripts/rehearse-helius-webhook.sh
#
# The script this exercises writes to a third party, and the writes are the
# expensive kind to get wrong: a wrong address set means a sponsor's deposit is
# not delivered, and a wrong `authHeader` means every delivery is refused. None
# of that can be tried out against production, and the interesting branches —
# create, edit, delete, skip — cannot all be reached on a host at once anyway,
# because they depend on how many deposit addresses exist at the time.
#
# So: run the real script with stub `docker` and `curl` on PATH, and assert on
# what it decided and on **what it would have sent**. The body is the part worth
# asserting; a script that reaches the right branch and posts the wrong JSON is
# the failure this catches.
#
# One thing is asserted negatively throughout, because it is the property that
# does not announce itself when it breaks: the API key, the webhook secret and
# the addresses must not appear in anything the script prints. `journalctl` is
# readable by anyone who can read the host.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

KEY="helius-key-not-a-real-one"
SECRET="0000000000000000000000000000000000000000000000000000000000000000"
A1="AaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaA"
A2="BbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbBbB"
A3="CcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcCcC"

# --- the environment file -------------------------------------------------
# Written rather than stubbed, because reading it is one of the things that has
# gone wrong before: `kolonie-infra#7` was a variable named one way in `.env` and
# another in the compose file, and every deploy failed for days.
env_file() {
    cat > "$WORK/.env" <<EOF
POSTGRES_USER=kolonie
POSTGRES_DB=kolonie
API_URL=https://api.example.invalid
HELIUS_API_KEY=${1-$KEY}
DEPOSIT_WEBHOOK_SECRET=${2-$SECRET}
EOF
}

# --- the stubs ------------------------------------------------------------
# ADDRESSES is what `deposit_addresses` holds, one per line. DB_FAILS makes the
# read fail, which must never be reported as "no addresses" — that would silently
# delete a live webhook.
cat > "$BIN/docker" <<'STUB'
#!/bin/bash
case "$1" in
  inspect) exit 0 ;;
  exec)
    if [ "${DB_FAILS:-}" = 1 ]; then echo "psql: could not connect" >&2; exit 1; fi
    printf '%s\n' "${ADDRESSES:-}" | sed '/^$/d'
    ;;
  *) echo "STUB: unexpected docker call: $*" >&2; exit 125 ;;
esac
STUB
chmod +x "$BIN/docker"

# WEBHOOKS is the JSON array the Helius listing returns. LIST_FAILS is an outage
# at Helius; WRITE_FAILS is a refused create/edit/delete. Every call is appended
# to $WORK/calls so the assertions can read what was sent.
cat > "$BIN/curl" <<'STUB'
#!/bin/bash
method=GET
body=
prev=
for arg in "$@"; do
  case "$prev" in
    -X) method="$arg" ;;
    -d) body="$arg" ;;
  esac
  prev="$arg"
done
{ echo "== $method"; echo "$@"; echo "BODY $body"; } >> "$CALLS"

if [ "$method" = GET ]; then
  if [ "${LIST_FAILS:-}" = 1 ]; then
    echo '{"error":"Unauthorized","key":"'"$HELIUS_KEY_FOR_STUB"'"}'
    exit 22
  fi
  printf '%s' "${WEBHOOKS:-[]}"
  exit 0
fi

if [ "${WRITE_FAILS:-}" = 1 ]; then
  echo '{"message":["nope"],"error":"Bad Request"}'
  exit 22
fi

case "$method" in
  POST) echo '{"webhookID":"new-id","accountAddresses":'"${SENT_ADDRESSES:-[]}"'}' ;;
  PUT)  echo '{"webhookID":"old-id","accountAddresses":'"${SENT_ADDRESSES:-[]}"'}' ;;
  DELETE) echo '{"message":"Webhook deleted successfully"}' ;;
esac
STUB
chmod +x "$BIN/curl"

sync() {
    CALLS="$WORK/calls" HELIUS_KEY_FOR_STUB="$KEY" \
    PATH="$BIN:$PATH" KOLONIE_ENV_FILE="$WORK/.env" \
        "$@" bash "$ROOT/scripts/helius-webhook.sh" ${DRY:-}
}

hook_json() {
    # One webhook, delivering where the script will look for it. Anything not
    # pointing at this URL must be left alone: the Colony's account may hold
    # webhooks for something else entirely.
    printf '[{"webhookID":"old-id","webhookURL":"https://api.example.invalid/v1/deposits/webhook","accountAddresses":[%s]}]' "$1"
}

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: [$2] not in [$1]"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }
reset()    { : > "$WORK/calls"; }

echo "== 1. no secret is a deliberate configuration, not a fault"
env_file "$KEY" ""
reset
out=$(ADDRESSES="$A1" sync 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "skipped: DEPOSIT_WEBHOOK_SECRET is unset" "said why"
check "asked Helius nothing" "$(wc -l < "$WORK/calls" | tr -d ' ')" "0"

echo "== 2. no key at all is a fault, and names the one key that must not be rotated"
env_file "" "$SECRET"
out=$(ADDRESSES="$A1" sync 2>&1); status=$?
check "exit 2" "$status" "2"
contains "$out" "HELIUS_API_KEY is unset" "named the variable"
contains "$out" "DEPOSIT_SEALING_KEY" "warned about its dangerous neighbour"

echo "== 3. no address and no webhook is the correct state, not a missing step"
env_file
reset
out=$(ADDRESSES="" WEBHOOKS="[]" sync 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "nothing to watch" "said so"
contains "$out" "Helius refuses a webhook with an empty address list" "explained why there is no webhook"
absent "$(cat "$WORK/calls")" "-X" "wrote nothing"

echo "== 4. the first address creates the webhook, and the body is the one Helius accepts"
reset
out=$(ADDRESSES="$A1" WEBHOOKS="[]" sync 2>&1); status=$?
calls=$(cat "$WORK/calls")
check "exit 0" "$status" "0"
contains "$out" "created: webhook new-id" "reported the id"
contains "$calls" "== POST" "created rather than edited"
body=$(sed -n 's/^BODY //p' "$WORK/calls" | tail -1)
check "webhookType" "$(jq -r .webhookType <<<"$body")" "enhanced"
check "transactionTypes" "$(jq -r '.transactionTypes|join(",")' <<<"$body")" "Any"
check "authHeader is the raw secret, no Bearer prefix" "$(jq -r .authHeader <<<"$body")" "$SECRET"
check "the address is in it" "$(jq -r '.accountAddresses|join(",")' <<<"$body")" "$A1"
check "delivers to the deposit route" "$(jq -r .webhookURL <<<"$body")" "https://api.example.invalid/v1/deposits/webhook"

echo "== 5. a webhook already watching exactly the right set is left alone"
reset
out=$(ADDRESSES="$A1
$A2" WEBHOOKS="$(hook_json "\"$A1\",\"$A2\"")" sync 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "unchanged: the webhook watches all 2 deposit address(es)" "said it changed nothing"
absent "$(cat "$WORK/calls")" "-X" "and wrote nothing"

echo "== 6. order is not a difference — the sets are compared, not the lists"
reset
out=$(ADDRESSES="$A2
$A1" WEBHOOKS="$(hook_json "\"$A1\",\"$A2\"")" sync 2>&1)
contains "$out" "unchanged" "a reordered list is still unchanged"
absent "$(cat "$WORK/calls")" "-X" "no pointless write every hour"

echo "== 7. a new address is added, and the whole set is sent rather than a delta"
reset
out=$(ADDRESSES="$A1
$A2
$A3" WEBHOOKS="$(hook_json "\"$A1\"")" SENT_ADDRESSES='["a","b","c"]' sync 2>&1); status=$?
calls=$(cat "$WORK/calls")
check "exit 0" "$status" "0"
contains "$calls" "== PUT" "edited the existing webhook"
contains "$out" "updating: 2 to add, 0 to drop, 3 watched after this" "counted the change"
body=$(sed -n 's/^BODY //p' "$WORK/calls" | tail -1)
check "sent all three, not the two new ones" "$(jq -r '.accountAddresses|length' <<<"$body")" "3"

echo "== 8. an address that is gone is dropped"
reset
out=$(ADDRESSES="$A1" WEBHOOKS="$(hook_json "\"$A1\",\"$A2\"")" SENT_ADDRESSES='["a"]' sync 2>&1)
contains "$out" "updating: 0 to add, 1 to drop, 1 watched after this" "counted the removal"

echo "== 9. the last address going means the webhook goes — an empty one cannot exist"
reset
out=$(ADDRESSES="" WEBHOOKS="$(hook_json "\"$A1\"")" sync 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$(cat "$WORK/calls")" "== DELETE" "deleted it"
contains "$out" "removed: no webhook is configured" "said so"

echo "== 10. a webhook belonging to something else is not touched"
reset
other='[{"webhookID":"someone-elses","webhookURL":"https://example.invalid/other","accountAddresses":["zzz"]}]'
out=$(ADDRESSES="$A1" WEBHOOKS="$other" SENT_ADDRESSES='["a"]' sync 2>&1)
contains "$(cat "$WORK/calls")" "== POST" "created its own rather than editing the stranger"
absent "$(cat "$WORK/calls")" "someone-elses" "never named the stranger's id in a call"

echo "== 11. a database it cannot read is a failure, never an empty set"
reset
out=$(DB_FAILS=1 WEBHOOKS="$(hook_json "\"$A1\"")" sync 2>&1); status=$?
check "exit 2" "$status" "2"
contains "$out" "could not read deposit_addresses" "said what it could not do"
absent "$(cat "$WORK/calls")" "== DELETE" "did not delete a live webhook on the strength of a failed query"

echo "== 12. Helius being down stops the run, and does not leak the key it was called with"
reset
out=$(LIST_FAILS=1 ADDRESSES="$A1" sync 2>&1); status=$?
check "exit 3" "$status" "3"
contains "$out" "would not list the webhooks" "said what failed"
absent "$out" "$KEY" "the key is masked out of the error body"
contains "$out" "<api-key>" "and visibly so, rather than by omission"

echo "== 13. a refused write is exit 3 and says which write"
reset
out=$(WRITE_FAILS=1 ADDRESSES="$A1" WEBHOOKS="[]" sync 2>&1); status=$?
check "exit 3" "$status" "3"
contains "$out" "Helius refused the create" "named the operation"

echo "== 14. --dry-run reaches the decision and stops before the write"
reset
out=$(DRY=--dry-run ADDRESSES="$A1" WEBHOOKS="[]" sync 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "dry-run: would POST the create" "said what it would have done"
absent "$(cat "$WORK/calls")" "== POST" "and did not do it"

echo "== 15. nothing it prints identifies a sponsor or carries a credential"
reset
out=$(ADDRESSES="$A1
$A2" WEBHOOKS="$(hook_json "\"$A1\"")" SENT_ADDRESSES='["a","b"]' sync 2>&1)
absent "$out" "$SECRET" "the webhook secret is never printed"
absent "$out" "$KEY" "the API key is never printed"
absent "$out" "$A1" "nor is a deposit address, which identifies a sponsor"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
