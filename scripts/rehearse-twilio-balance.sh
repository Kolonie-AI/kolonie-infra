#!/bin/bash
# Rehearse the Twilio balance row without Twilio, a host, or money (#83).
#
# Usage: ./scripts/rehearse-twilio-balance.sh
#
# The thing this exercises is an **alarm**, and an alarm has exactly two ways to
# be worthless: it does not fire when it should, and it fires when it should not.
# Neither is observable in production until the day it matters — the balance was
# $48.84 on 2026-08-05, which at DE rates is roughly four hundred more messages,
# and that is precisely why nobody will notice this is broken.
#
# So: run the real `health-report.sh` with a stub `curl` on PATH and a stub
# `docker` that reports no containers, and assert on the row it emits. Then feed
# that row to the real `health-triage.sh` and assert on the verdict. The two
# halves are separate because they fail separately — a report that measures
# correctly and a triage that judges wrongly look identical from either end.
#
# Four cases, which are the four the issue names: a healthy balance, one under
# the threshold, an unreachable vendor, and absent configuration.
#
# **One property is asserted negatively throughout**, because it is the one that
# does not announce itself when it breaks: the account SID, the key SID and the
# key secret must appear in nothing either script prints. The health workflow's
# log is public.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

# Not credentials. Distinctive enough that a leak into output is unambiguous.
SID="ACrehearsalrehearsalrehearsalrehe"
KEY_SID="SKrehearsalrehearsalrehearsalrehe"
KEY_SECRET="rehearsal-secret-not-a-real-one"

FAILED=0

pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1"
    [ -n "${2-}" ] && printf '       %s\n' "$2"
    FAILED=1
}

# --- the stubs ------------------------------------------------------------
# `docker` reports nothing, so the report emits NO_CONTAINERS and its own rows
# and nothing else. The container half is rehearse-deploy.sh's business.
cat > "$BIN/docker" <<'EOF'
#!/bin/bash
exit 0
EOF

# `curl` answers whatever the case under test wrote into BALANCE_BODY, and exits
# non-zero when it is empty — which is what `--fail` and an unreachable host both
# look like to the caller.
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
if [ -z "${STUB_BALANCE_BODY:-}" ]; then
    exit 22
fi
printf '%s' "$STUB_BALANCE_BODY"
EOF

chmod +x "$BIN/docker" "$BIN/curl"

report() {
    PATH="$BIN:$PATH" \
    STUB_BALANCE_BODY="${1-}" \
    TWILIO_ACCOUNT_SID="${2-$SID}" \
    TWILIO_API_KEY_SID="${3-$KEY_SID}" \
    TWILIO_API_KEY_SECRET="${4-$KEY_SECRET}" \
    KOLONIE_DEPLOY_DIR="$WORK/deploy" \
        bash "$ROOT/scripts/health-report.sh" 2>/dev/null
}

triage() {
    printf '%s\n' "$1" | SMS_LOW_MESSAGES="${2:-200}" bash "$ROOT/scripts/health-triage.sh" 2>/dev/null
}

sms_row() { printf '%s\n' "$1" | awk -F'\t' '$1 == "sms" { print }'; }

# The report only emits its non-container rows where a deploy directory exists.
mkdir -p "$WORK/deploy"

echo "rehearsing the Twilio balance alarm (#83)"

# --- 1. a healthy balance -------------------------------------------------
out=$(report '{"balance":"48.84","currency":"USD"}')
row=$(sms_row "$out")
remaining=$(printf '%s' "$row" | cut -f5)

if [ "$(printf '%s' "$row" | cut -f2)" = "ok" ]; then
    pass "a healthy balance is ok"
else
    fail "a healthy balance is ok" "got: $row"
fi

# $48.84 at the pessimistic 12c is 407 — the report rounds the price up on
# purpose, so what is left is understated rather than overstated. The assertion
# is that the row is denominated in **messages**: 48 or 4884 would both mean it
# had handed the triage money instead.
if [ "$remaining" = "407" ]; then
    pass "the row carries messages remaining, not dollars ($remaining)"
else
    fail "the row carries messages remaining, not dollars" "got: $remaining"
fi

verdict=$(triage "$row")
if printf '%s' "$verdict" | grep -qi "SMS balance"; then
    pass "a healthy balance is listed as healthy"
else
    fail "a healthy balance is listed as healthy" "got: $verdict"
fi

# --- 2. under the threshold -----------------------------------------------
# $2.00 at $0.112 is about 17 messages, well under any sane threshold.
out=$(report '{"balance":"2.00","currency":"USD"}')
row=$(sms_row "$out")
verdict=$(triage "$row")

if printf '%s' "$verdict" | grep -q "messages left at the dearest allowed destination"; then
    pass "a low balance is a problem"
else
    fail "a low balance is a problem" "got: $verdict"
fi

if printf '%s' "$verdict" | grep -q "Auto-recharge is off on"; then
    pass "the closing advice explains why nothing else would notice"
else
    fail "the closing advice explains why nothing else would notice" "got: $verdict"
fi

# --- 3. the vendor is unreachable -----------------------------------------
# **The case this whole alarm is most likely to get wrong.** A blip reported as
# `low` is an alarm somebody mutes, after which the real one is not heard either.
out=$(report '')
row=$(sms_row "$out")

if [ "$(printf '%s' "$row" | cut -f2)" = "unknown" ]; then
    pass "an unreachable vendor is unknown"
else
    fail "an unreachable vendor is unknown" "got: $row"
fi

verdict=$(triage "$row")
if printf '%s' "$verdict" | grep -q "did not answer when asked for the balance" &&
    ! printf '%s' "$verdict" | grep -q "messages left"; then
    pass "an unreachable vendor is never reported as low"
else
    fail "an unreachable vendor is never reported as low" "got: $verdict"
fi

# A body that is not the JSON expected is the same answer, and for the same
# reason: what was measured is nothing, and nothing is not zero.
out=$(report '<html>504 Gateway Timeout</html>')
if [ "$(sms_row "$out" | cut -f2)" = "unknown" ]; then
    pass "an answer that is not a balance is unknown, not zero"
else
    fail "an answer that is not a balance is unknown, not zero" "got: $(sms_row "$out")"
fi

# --- 4. no Twilio account -------------------------------------------------
# A Colony with no Twilio account is not unhealthy, and a row saying `unknown` on
# every workstation run is how a watcher gets ignored.
out=$(report '{"balance":"48.84","currency":"USD"}' '' '' '')
if [ -z "$(sms_row "$out")" ]; then
    pass "no configuration means no row at all"
else
    fail "no configuration means no row at all" "got: $(sms_row "$out")"
fi

out=$(report '{"balance":"48.84","currency":"USD"}' "$SID" "$KEY_SID" '')
if [ -z "$(sms_row "$out")" ]; then
    pass "a half-configured account means no row either"
else
    fail "a half-configured account means no row either" "got: $(sms_row "$out")"
fi

# --- 5. the values come out of .env ---------------------------------------
# **The case that decides whether any of this runs in production.**
# health-watch.yml invokes the report over SSH as `cd $DEPLOY_DIR &&
# ./scripts/health-report.sh`, and a login shell there carries no `TWILIO_*` —
# they live in `$DEPLOY_DIR/.env`, which Compose reads and ssh does not. A check
# that only read the environment would pass every case above and emit nothing,
# for ever.
cat > "$WORK/deploy/.env" <<EOF
POSTGRES_PASSWORD=not-a-real-password
TWILIO_ACCOUNT_SID=$SID
TWILIO_API_KEY_SID=$KEY_SID
TWILIO_API_KEY_SECRET=$KEY_SECRET
EOF

out=$(report '{"balance":"48.84","currency":"USD"}' '' '' '')
row=$(sms_row "$out")

if [ "$(printf '%s' "$row" | cut -f2)" = "ok" ] && [ "$(printf '%s' "$row" | cut -f5)" = "407" ]; then
    pass "the credentials are read out of .env when the shell has none"
else
    fail "the credentials are read out of .env when the shell has none" "got: $row"
fi

# And a `.env` without them still means no row, so the file being present is not
# itself the trigger.
cat > "$WORK/deploy/.env" <<'EOF'
POSTGRES_PASSWORD=not-a-real-password
EOF

out=$(report '{"balance":"48.84","currency":"USD"}' '' '' '')
if [ -z "$(sms_row "$out")" ]; then
    pass "a .env without Twilio still means no row"
else
    fail "a .env without Twilio still means no row" "got: $(sms_row "$out")"
fi

rm -f "$WORK/deploy/.env"

# --- 6. nothing prints a credential ---------------------------------------
# Asserted over everything the two scripts emitted across every case above,
# rather than over one of them: the leak this guards against is a `set -x`, a
# debug echo or an error path printing the URL it built.
all=$(
    report '{"balance":"48.84","currency":"USD"}'
    report ''
    report '<html>504</html>'
    triage "$(sms_row "$(report '{"balance":"2.00","currency":"USD"}')")"
)

leaked=0
for secret in "$SID" "$KEY_SID" "$KEY_SECRET"; do
    printf '%s' "$all" | grep -q -- "$secret" && leaked=1
done

if [ "$leaked" -eq 0 ]; then
    pass "no account SID, key SID or key secret appears in any output"
else
    fail "no account SID, key SID or key secret appears in any output"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all cases pass"
else
    echo "REHEARSAL FAILED"
fi
exit "$FAILED"
