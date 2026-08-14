#!/bin/bash
# Take a triage script's verdict out of its stderr and put it on the step's
# output — and take nothing else (#163).
#
# Usage: ./scripts/verdict-out.sh <stderr-file>
#
# ## Why this exists
#
# The three triage scripts write their markdown to stdout and two
# machine-readable lines to stderr:
#
#     VERDICT=ok|degraded|drifted|unknown
#     FINGERPRINT=<stable digest of what is wrong>
#
# The workflow captured that with `2> verdict.env` and then did
# `cat verdict.env >> "$GITHUB_OUTPUT"`. That reads as though stderr were the
# script's private channel. It is not. **Stderr is shared with every diagnostic
# bash, `gh` or any tool in the pipeline can emit**, and `$GITHUB_OUTPUT` rejects
# the whole file if one line of it is not `KEY=value`.
#
# On 2026-08-14, run 31777542101, it did:
#
#     ##[error]Unable to process file command 'output' successfully.
#     ##[error]Invalid format './scripts/drift-triage.sh: line 169: printf:
#              write error: Broken pipe'
#
# The host was healthy, every service was reported `current`, and the step died
# anyway — taking with it the step that files the report and everything below it.
# That is `#104`'s failure a second time: not in the script with the judgement in
# it, but in the line of the workflow that reads it.
#
# The broken pipe itself is fixed at its source in `drift-triage.sh`. This exists
# because fixing that one instance leaves the class open — the next `gh` warning
# on stderr does exactly the same thing, and it will not be preceded by an issue
# explaining what to look for.
#
# ## What it refuses, and why that is not the same as passing everything through
#
# A file with no `VERDICT=` line is a **failure**, and this exits 1 saying so
# with the file's contents attached. A triage script that produced no verdict has
# not run, and the step that reads `steps.<id>.outputs.VERDICT` would otherwise
# get an empty string — which every consumer below reads as *nothing to report*.
# A watcher that reports "ok" because it is broken is the failure this workflow
# exists to end, and it is worth one explicit refusal here.
#
# Anything else in the file is printed rather than dropped. It is the diagnostic
# somebody will want when they come to read why a run looked odd, and losing it
# to make the format valid would be trading one silence for another.
set -uo pipefail

SRC=${1:?usage: verdict-out.sh <stderr-file>}

# Unset when this is rehearsed, and writing to stdout is the right fallback:
# a rehearsal that had to invent a GITHUB_OUTPUT would be testing the invention.
OUT=${GITHUB_OUTPUT:-/dev/stdout}

if [ ! -f "$SRC" ]; then
    echo "::error::$SRC does not exist — the triage step wrote no stderr at all."
    exit 1
fi

# The two keys the channel is defined to carry. Anchored, because a diagnostic
# quoting one of them mid-sentence is a diagnostic and not a verdict.
KEYS='^(VERDICT|FINGERPRINT)='

verdict_lines=$(grep -E "$KEYS" "$SRC" || true)
other=$(grep -Ev "$KEYS" "$SRC" || true)

if ! printf '%s\n' "$verdict_lines" | grep -q '^VERDICT='; then
    echo "::error::No VERDICT= line in $SRC. The triage script did not reach its verdict."
    [ -n "$other" ] && printf '%s\n' "$other" | sed 's/^/  /'
    exit 1
fi

printf '%s\n' "$verdict_lines" >> "$OUT"

# Not an error and not dropped. A broken pipe, a `gh` deprecation notice or a
# shellcheck-shaped warning all land here, and the run stays green — the verdict
# arrived, which is what the step was for.
if [ -n "$other" ]; then
    echo "::notice::$SRC also carried output that is not a verdict line:"
    printf '%s\n' "$other" | sed 's/^/  /'
fi
