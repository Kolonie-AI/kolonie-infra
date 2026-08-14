#!/bin/bash
# Rehearse verdict-out.sh — what reaches the step output, and what does not (#163).
#
# Usage: ./scripts/rehearse-verdict-out.sh
#
# The script this rehearses has one judgement in it: which lines of a triage
# script's stderr are a verdict and which are a diagnostic that happened to land
# in the same file. Both cases are real and both were seen on 2026-08-14 — a
# `VERDICT=ok` and a `printf: write error: Broken pipe`, in that order, in the
# file the workflow appended to `$GITHUB_OUTPUT`.
#
# The rejection case is the one worth having: a file with **no** verdict in it
# must fail, because a step that silently produces no `VERDICT` output hands
# every consumer below it an empty string, and every consumer below reads an
# empty string as *nothing to report*.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() {
    local name=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        printf '  ok   %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n         want %q, got %q\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}

contains() {
    case "$1" in
    *"$2"*)
        printf '  ok   %s\n' "$3"
        pass=$((pass + 1))
        ;;
    *)
        printf '  FAIL %s\n         %q not in output\n' "$3" "$2"
        fail=$((fail + 1))
        ;;
    esac
}

absent() {
    case "$1" in
    *"$2"*)
        printf '  FAIL %s\n         %q is in the output and should not be\n' "$3" "$2"
        fail=$((fail + 1))
        ;;
    *)
        printf '  ok   %s\n' "$3"
        pass=$((pass + 1))
        ;;
    esac
}

# Runs the real script with a real GITHUB_OUTPUT file, and answers with what
# landed in it. The log the step would print goes to $WORK/log.
emit() {
    : > "$WORK/out"
    GITHUB_OUTPUT="$WORK/out" bash "$ROOT/scripts/verdict-out.sh" "$1" > "$WORK/log" 2>&1
    printf '%s' $?
}

echo "== 1. a clean verdict passes through unchanged"
printf 'VERDICT=ok\nFINGERPRINT=ok\n' > "$WORK/clean.env"
status=$(emit "$WORK/clean.env")
check "exit 0" "$status" "0"
check "both lines, in order" "$(cat "$WORK/out")" "$(printf 'VERDICT=ok\nFINGERPRINT=ok')"

echo
echo "== 2. the case that broke the watcher: a diagnostic beside the verdict"
# Run 31777542101, verbatim in shape: the script reached its verdict, and bash
# wrote a broken-pipe line into the same channel. `$GITHUB_OUTPUT` refused the
# whole file and the step died with the host perfectly healthy.
{
    echo "./scripts/drift-triage.sh: line 169: printf: write error: Broken pipe"
    echo "VERDICT=ok"
    echo "FINGERPRINT=ok"
} > "$WORK/dirty.env"
status=$(emit "$WORK/dirty.env")
check "exit 0 — the verdict arrived, so the step succeeds" "$status" "0"
absent "$(cat "$WORK/out")" "Broken pipe" "the diagnostic never reaches \$GITHUB_OUTPUT"
contains "$(cat "$WORK/out")" "VERDICT=ok" "the verdict does"
contains "$(cat "$WORK/log")" "Broken pipe" "and it is printed rather than dropped"

echo
echo "== 3. REJECTION: a file with no verdict in it fails the step"
# The whole reason this is not a `grep || true`. A triage script that produced
# no verdict has not run, and an empty VERDICT output reads downstream as "ok".
echo "gh: something went wrong" > "$WORK/noverdict.env"
status=$(emit "$WORK/noverdict.env")
check "exit 1" "$status" "1"
check "nothing written to the output" "$(cat "$WORK/out")" ""
contains "$(cat "$WORK/log")" "did not reach its verdict" "said why"
contains "$(cat "$WORK/log")" "gh: something went wrong" "quoted what it did find"

echo
echo "== 4. REJECTION: an empty stderr file is not a pass"
: > "$WORK/empty.env"
status=$(emit "$WORK/empty.env")
check "exit 1" "$status" "1"
check "nothing written to the output" "$(cat "$WORK/out")" ""

echo
echo "== 5. REJECTION: a missing file says so rather than passing silently"
status=$(emit "$WORK/does-not-exist.env")
check "exit 1" "$status" "1"
contains "$(cat "$WORK/log")" "does not exist" "named the file"

echo
echo "== 6. a key quoted inside a diagnostic is a diagnostic"
# Anchored matching, so a sentence mentioning VERDICT= mid-line cannot become
# one. This is what stops an error message being read as a finding.
printf 'gh: expected VERDICT=ok and got nothing\nVERDICT=degraded\nFINGERPRINT=disk:full\n' \
    > "$WORK/quoted.env"
status=$(emit "$WORK/quoted.env")
check "exit 0" "$status" "0"
check "only the real lines" "$(cat "$WORK/out")" \
    "$(printf 'VERDICT=degraded\nFINGERPRINT=disk:full')"

echo
echo "== 7. every triage script's channel is the shape this reads"
# Asserted against the scripts rather than against a fixture, so that a triage
# script changing its key names fails here instead of at 03:00 on the host.
for s in health-triage pin-triage drift-triage; do
    if grep -qE 'echo "VERDICT=|printf .VERDICT=' "$ROOT/scripts/$s.sh"; then
        printf '  ok   %s writes VERDICT= to its channel\n' "$s"
        pass=$((pass + 1))
    else
        printf '  FAIL %s writes no VERDICT= line this can read\n' "$s"
        fail=$((fail + 1))
    fi
done

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
