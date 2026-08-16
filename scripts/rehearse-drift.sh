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
# HISTORY holds what the jq in `sha_history` produces from GHCR's version list:
# one `<sha>\t<created_at>` row per tagged build, newest first. The timestamp is
# there because the grace window is measured against it (`#193`), and it is in the
# fixture rather than defaulted in the script because GHCR always sends it — a
# script that coped with its absence would be coping with a case only this file
# could produce.
#
# GH_FAILS makes the call fail outright, which is what an outage at GitHub looks
# like and must not be reported as "no drift".
cat > "$BIN/gh" <<'STUB'
#!/bin/bash
if [ "${GH_FAILS:-}" = 1 ]; then
  # What gh actually writes: a status line and the API's message. The report
  # quotes this, so the stub has to produce something shaped like it (#50).
  echo "${GH_ERROR:-gh: Package not found. (HTTP 404)}" >&2
  exit 1
fi
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

# An ISO timestamp this many minutes in the past, in GHCR's own format.
ago() { date -u -d "@$(( $(date -u +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }

# A build history whose newest image is $1 minutes old. Every case below except
# the two window cases wants an image old enough that the window has passed, so
# the default puts it two hours back and the older builds behind it.
hist() {
  local age="${1:-120}"
  printf '%s\t%s\n%s\t%s\n%s\t%s\n' \
    "$NEW" "$(ago "$age")" \
    "$OLD" "$(ago $((age + 60)))" \
    "$OLDER" "$(ago $((age + 120)))"
}
HIST="$(hist)"

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

echo "== 3b. a package GHCR answers for but has never tagged is a different unknown"
# Distinct from a refusal: nothing to fix at the token, nothing has been built.
out=$(printf 'api\t%s\timg\n' "$NEW" | PATH="$BIN:$PATH" HISTORY="" bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v")
contains "$(cat "$WORK/v")" "VERDICT=unknown" "verdict unknown"
contains "$out" "GHCR lists no tagged build" "said the package is empty"
absent "$out" "refused the request" "and did not blame the token"

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
contains "$out" "GHCR refused the request" "said GHCR refused, not that there was no build"
contains "$out" "Package not found. (HTTP 404)" "and quoted what GHCR actually said"
absent "$out" "The host is not serving" "did not claim drift it cannot see"
contains "$out" "could not be placed" "used the heading that matches the verdict"

echo "== 6b. the reason is whatever GHCR said, not a guess about it"
# #50: the first version discarded gh's stderr and reported only that the call
# had failed. The issue filed off that run named a per-package permission —
# inferred from an exit code rather than read from an error. Same mistake #43
# exists to correct one level up.
out=$(printf 'api\t%s\timg\n' "$NEW" | PATH="$BIN:$PATH" GH_FAILS=1 \
        GH_ERROR="gh: Resource not accessible by integration (HTTP 403)" \
        bash "$ROOT/scripts/drift-triage.sh" 2>/dev/null)
contains "$out" "Resource not accessible by integration (HTTP 403)" "carried a different reason through unchanged"
absent "$out" "Package not found" "and did not substitute a stock explanation"

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

echo "== 11. every service this organisation builds is one the check can place (#149)"
# `support-triage-runner` and `badge-runner` were absent from the mapping and
# reported `unknown — no GHCR package is mapped to this service`, which reads as
# a gap at GHCR and was a `case` statement here. Both are built on every deploy.
#
# Asserted over `KOLONIE_SERVICES` rather than over the two that were missing:
# the fault was a list kept in two places, so a test naming today's two would
# pass again the next time a seventh service is added to one of them.
# shellcheck source=scripts/services.sh
. "$ROOT/scripts/services.sh"
for svc in "${KOLONIE_SERVICES[@]}"; do
  out=$(printf '%s\t%s\timg\n' "$svc" "$NEW" | triage 2>/dev/null)
  absent "$out" "no GHCR package is mapped" "$svc can be placed"
done

echo "== 12. a service behind an image younger than the window is a rollout, not drift (#193)"
# The nineteen self-closing reports in six days were all this shape, and #191 was
# filed six seconds before the deploy it described finished. The image reaches
# GHCR before it reaches the host; the gap between those is not a fault.
out=$(printf 'api\t%s\timg\n' "$OLD" | PATH="$BIN:$PATH" HISTORY="$(hist 2)" \
        bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v"); status=$?
check "exit 0 — nothing to correct" "$status" "0"
contains "$(cat "$WORK/v")" "VERDICT=ok" "verdict ok, so nothing is filed"
contains "$out" "deploy in flight" "named the state"
contains "$out" "built 2 min ago" "and said how young the image is"
absent "$out" "behind by" "did not call a rollout drift"
absent "$out" "The host is not serving" "and did not use the drift heading"
contains "$out" "A deploy is in flight" "used a heading that is not 'everything is current'"

echo "== 12b. the same service behind an image past the window still drifts"
# The window delays; it does not hide. A deploy that failed leaves the image
# ageing, and the run past the window reports exactly as it does today.
out=$(printf 'api\t%s\timg\n' "$OLD" | PATH="$BIN:$PATH" HISTORY="$(hist 120)" \
        bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v"); status=$?
check "exit 1" "$status" "1"
contains "$(cat "$WORK/v")" "VERDICT=drifted" "verdict drifted"
contains "$out" "behind by 1" "counted the gap as before"
absent "$out" "deploy in flight" "and did not excuse it"

echo "== 12c. the window is one number, and a rehearsal can pin it"
# Same two-minute-old image, window narrowed below it: the point is that the
# behaviour above follows from the window rather than from the age being small.
out=$(printf 'api\t%s\timg\n' "$OLD" | PATH="$BIN:$PATH" HISTORY="$(hist 10)" \
        KOLONIE_DRIFT_GRACE_MINUTES=5 bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v"); status=$?
check "exit 1 — ten minutes is outside a five-minute window" "$status" "1"
contains "$(cat "$WORK/v")" "VERDICT=drifted" "verdict drifted"

echo "== 12d. the window is measured against the oldest build a service is missing"
# The whole risk of a grace window is the report it swallows. Here the newest
# image is two minutes old, so a rule that asked "is the newest image young?"
# would excuse both rows. `website` is two builds back and the first one it
# missed landed over two hours ago: that host missed a deploy, and no rollout in
# progress makes it current. `api` is behind by exactly that fresh image, which
# is what the middle of a rollout looks like.
out=$(printf 'api\t%s\timg\nwebsite\t%s\timg\n' "$OLD" "$OLDER" | PATH="$BIN:$PATH" \
        HISTORY="$(printf '%s\t%s\n%s\t%s\n%s\t%s\n' \
          "$NEW" "$(ago 2)" "$OLD" "$(ago 130)" "$OLDER" "$(ago 190)")" \
        bash "$ROOT/scripts/drift-triage.sh" 2>"$WORK/v"); status=$?
check "exit 1" "$status" "1"
contains "$(cat "$WORK/v")" "VERDICT=drifted" "verdict drifted"
contains "$out" "| \`api\` | deploy in flight |" "the rollout is excused"
contains "$out" "| \`website\` | **behind by 2** |" "the missed deploy is not"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
