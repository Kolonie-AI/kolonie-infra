#!/bin/bash
# Rehearse drift-triage.sh without GHCR, a host, or a network (#44).
#
# Usage: ./scripts/rehearse-drift.sh
#
# `drift-triage.sh` is the part of the drift check with a judgement in it, and
# the judgement is the part worth testing: whether a service is current, one
# build behind, or something this check cannot place at all. Those three have to
# stay distinguishable, because collapsing `unknown` into either of the others is
# how a watcher becomes noise and then gets ignored.
#
# So: run the real script with a stub `gh` on PATH that answers the one API call
# it makes, and assert on the verdict, the summary and the exit status.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

# --- the stub -------------------------------------------------------------
# HISTORY holds the tag list GHCR would return, newest build first, one per
# line. GH_FAILS makes the call fail outright, which is what an outage at GitHub
# looks like and must not be reported as "no drift".
cat > "$BIN/gh" <<'STUB'
#!/bin/bash
[ "${GH_FAILS:-}" = 1 ] && exit 1
# Only one call is made: the package version listing. Anything else is a change
# in drift-triage.sh that this stub has not been taught about, and it should be
# loud rather than answer plausibly.
case "$*" in
  *packages/container/*) printf '%s\n' "${HISTORY:-}" ;;
  *) echo "STUB: unexpected gh call: $*" >&2; exit 125 ;;
esac
STUB
chmod +x "$BIN/gh"

NEW=$(printf 'a%039d' 1)
OLD=$(printf 'b%039d' 2)
OLDER=$(printf 'c%039d' 3)
STRANGER=$(printf 'd%039d' 4)
HIST="$NEW
$OLD
$OLDER"

triage() {
  PATH="$BIN:$PATH" HISTORY="$HIST" "$@" bash "$ROOT/scripts/drift-triage.sh"
}

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

echo "== 1. a service on the newest build is current, and says nothing alarming"
out=$(printf 'api\t%s\timg\n' "$NEW" | triage 2>"$WORK/v"); status=$?
check "exit 0" "$status" "0"
contains "$(cat "$WORK/v")" "VERDICT=ok" "verdict ok"
contains "$out" "Every service is running the newest image built for it" "said so plainly"
absent "$out" "behind" "nothing called behind"

echo "== 2. a service one build back is behind, by a number"
out=$(printf 'api\t%s\timg\n' "$OLD" | triage 2>"$WORK/v"); status=$?
check "exit 1" "$status" "1"
contains "$(cat "$WORK/v")" "VERDICT=drifted" "verdict drifted"
contains "$out" "behind by 1" "counted the gap"
contains "$out" "newest is" "and named what it should be running"

echo "== 3. two builds back counts two, not one"
out=$(printf 'api\t%s\timg\n' "$OLDER" | triage 2>/dev/null)
contains "$out" "behind by 2" "counted correctly"

echo "== 4. an image with no revision label is unknown, not current"
# Every image built before kolonie-platform#75 is this case. Reporting it as
# current would be a check that passes because it cannot see.
out=$(printf 'api\t-\timg\n' | triage 2>"$WORK/v"); status=$?
check "exit 0 — unknown is not a host fault" "$status" "0"
contains "$(cat "$WORK/v")" "VERDICT=unknown" "verdict unknown"
contains "$out" "carries no revision label" "said why it could not tell"
absent "$out" "behind by" "and did not invent a distance"

echo "== 5. a revision GHCR does not list is unknown, not behind"
out=$(printf 'api\t%s\timg\n' "$STRANGER" | triage 2>"$WORK/v")
contains "$(cat "$WORK/v")" "VERDICT=unknown" "verdict unknown"
contains "$out" "which GHCR does not list" "said what it could not place"

echo "== 6. GHCR being unreachable is never reported as no drift"
# An outage at GitHub read as "everything is current" is the reassuring silence
# this whole workflow exists to end.
out=$(printf 'api\t%s\timg\n' "$NEW" | PATH="$BIN:$PATH" GH_FAILS=1 bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v")
contains "$(cat "$WORK/v")" "VERDICT=unknown" "verdict unknown, not ok"
contains "$out" "GHCR listed no tagged build" "said it could not ask"

echo "== 7. one behind service among current ones still drifts the verdict"
out=$(printf 'api\t%s\timg\nwebsite\t%s\timg\n' "$NEW" "$OLD" | triage 2>"$WORK/v"); status=$?
check "exit 1" "$status" "1"
contains "$(cat "$WORK/v")" "VERDICT=drifted" "verdict drifted"
contains "$out" "| \`api\` | current |" "the current one is still reported as current"
contains "$out" "behind by 1" "and the behind one is named"

echo "== 8. the fingerprint is stable while the fault is, and moves when it changes"
fp1=$(printf 'api\t%s\timg\n' "$OLD" | triage 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
fp2=$(printf 'api\t%s\timg\n' "$OLD" | triage 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
fp3=$(printf 'api\t%s\timg\nwebsite\t%s\timg\n' "$OLD" "$OLD" | triage 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
check "same fault, same fingerprint" "$fp1" "$fp2"
check "a second service behind changes it" "$([ "$fp1" != "$fp3" ] && echo differs || echo same)" "differs"

echo "== 9. an empty probe is a broken watcher, not a healthy host"
out=$(printf '' | triage 2>"$WORK/v"); status=$?
check "exit 2 — distinct from both ok and drifted" "$status" "2"
contains "$out" "returned no rows" "said the probe was empty"

echo "== 10. it never deploys anything"
# Detecting drift and correcting it are different decisions (AGENTS.md §8).
out=$(printf 'api\t%s\timg\n' "$OLD" | triage 2>/dev/null)
contains "$out" "This reports; it does not deploy" "said so in the report a person reads"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
