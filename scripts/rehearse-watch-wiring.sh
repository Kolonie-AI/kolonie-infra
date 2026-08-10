#!/bin/bash
# Rehearse the shell wiring of health-watch.yml, not its scripts (#104).
#
# Usage: ./scripts/rehearse-watch-wiring.sh
#
# ## Why a rehearsal for a workflow file
#
# Every triage script this repository has is rehearsed. `rehearse-drift.sh`
# asserts that `drift-triage.sh` exits **1** when the host has drifted and **2**
# when the script itself could not run, and it has asserted that correctly the
# whole time. The bug in `#104` was not in any of them.
#
# It was in the four lines of `health-watch.yml` that call them. GitHub runs a
# `run:` block through `/usr/bin/bash -e`, and `set -uo pipefail` at the top of
# the block does not unset that — omitting `-e` from a `set` line never could.
# So this:
#
#     ./scripts/drift-triage.sh < revisions.out > drift.md 2> drift-verdict.env
#     status=$?
#
# ends the step on the first drifted host, and `status=$?` never runs. The step
# was written to distinguish 0, 1 and 2, and could only ever see 0.
#
# **The cost was a day of silence with a green face on it.** From 2026-08-09
# 08:02 the drift step died at exactly the moment it had something to report,
# every step below it was skipped, and the health step went on succeeding — so
# the workflow looked like a working watcher while two of the three things it
# watches went unwatched.
#
# ## What is asserted, and what deliberately is not
#
# **The pattern, not the semantics.** A rehearsal cannot run a GitHub workflow,
# and proving that `bash -e` exits on a non-zero command would be testing bash.
# What it can do is refuse the shape that hides an exit status, in the file where
# that shape did the damage — which is the check that would have caught this on
# the commit that introduced it.
#
# **Nothing about which scripts exist.** `check-services.sh` and the other
# rehearsals cover that. A second opinion here would be a second thing to keep
# true.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/health-watch.yml"

FAILURES=0

check() {
    local name=$1 ok=$2 detail=${3:-}
    if [ "$ok" = yes ]; then
        printf '  ok   %s\n' "$name"
    else
        printf '  FAIL %s\n' "$name"
        [ -n "$detail" ] && printf '%s\n' "$detail" | sed 's/^/         /'
        FAILURES=$((FAILURES + 1))
    fi
}

[ -f "$WORKFLOW" ] || { echo "no $WORKFLOW"; exit 2; }

echo
echo "a triage script's exit status is captured, never left to \`bash -e\`"

# Every line that invokes a triage script, with its line number. These are the
# calls whose exit status carries a finding rather than a failure.
calls=$(grep -n '\./scripts/[a-z-]*-triage\.sh' "$WORKFLOW" || true)

check "the workflow still calls at least one triage script" \
    "$([ -n "$calls" ] && echo yes || echo no)" \
    "if these were renamed, this rehearsal is checking nothing"

while IFS= read -r call; do
    [ -n "$call" ] || continue
    line=${call%%:*}
    text=${call#*:}
    script=$(printf '%s' "$text" | grep -oE 'scripts/[a-z-]*-triage\.sh')

    # Two shapes are safe: `|| status=$?`, which is what the step needs when it
    # goes on to read the status, and `|| true`, which is what the health step
    # uses because it reads the verdict out of a file instead. A bare call is
    # the defect.
    if printf '%s' "$text" | grep -qE '\|\|[[:space:]]*(status=\$\?|true)'; then
        check "$script (line $line) keeps its exit status" yes
    else
        check "$script (line $line) keeps its exit status" no \
            "$text
this ends the step under \`bash -e\` before anything can read \$?"
    fi
done <<< "$calls"

echo
echo "a step that reads \$? on its own line is not reading it after a bare call"

# The specific shape that broke: `status=$?` on the line after an unguarded
# call. Caught by looking for `status=$?` whose previous non-blank line is a
# triage invocation with no `||`.
previous=""
lineno=0
bare=0
while IFS= read -r text; do
    lineno=$((lineno + 1))
    trimmed=$(printf '%s' "$text" | sed 's/^[[:space:]]*//')
    if [ "$trimmed" = 'status=$?' ]; then
        if printf '%s' "$previous" | grep -qE '\./scripts/[a-z-]*-triage\.sh' &&
            ! printf '%s' "$previous" | grep -qE '\|\|'; then
            check "line $lineno reads \$? after a guarded call" no "$previous"
            bare=$((bare + 1))
        fi
    fi
    [ -n "$trimmed" ] && previous=$text
done < "$WORKFLOW"

check "no \`status=\$?\` follows an unguarded triage call" \
    "$([ "$bare" -eq 0 ] && echo yes || echo no)"

echo
echo "the watcher reports its own failure"

# `#104`'s other half: the steps above report what they find, and nothing
# reported that they had not run. These two assertions are what stop that
# arrangement being deleted as redundant later.
check "a failed run files a report" \
    "$(grep -q 'if: failure()' "$WORKFLOW" && echo yes || echo no)" \
    "no step runs on failure, so a half-finished run says nothing"

check "a run that gets through closes it" \
    "$(grep -q 'if: success()' "$WORKFLOW" && echo yes || echo no)" \
    "an issue nothing closes is one people learn to ignore"

check "the self-report has a title of its own" \
    "$(grep -q 'SELF_ISSUE_TITLE:' "$WORKFLOW" && echo yes || echo no)"

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failed"
    exit 1
fi
echo "all good"
