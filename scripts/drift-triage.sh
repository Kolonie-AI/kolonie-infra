#!/bin/bash
# Kolonie AI — is the host serving what was last built? (#44)
#
# Reads the rows scripts/deployed-revision.sh produces on stdin and decides
# whether the host has fallen behind. Separate from the probe and from the
# workflow for the same reason health-triage.sh is: this is the part with a
# judgement in it, so it is the part that has to be testable without a deploy
# host.
#
#   ./scripts/deployed-revision.sh | ./scripts/drift-triage.sh
#
# Writes a markdown summary to stdout, and two machine-readable lines to stderr:
#
#   VERDICT=ok|drifted|unknown
#   FINGERPRINT=<stable digest of what is behind>
#
# ## What it compares against, and why not `main`
#
# The obvious reference is the head commit of `kolonie-platform`, and it is
# wrong. A commit that touches only the website does not rebuild the api — the
# `changes` job in that repository exists precisely so it does not — so the api's
# revision legitimately trails `main` most of the time. A check that called that
# drift would be wrong on almost every run, and a check that is wrong on almost
# every run gets switched off before the day it would have been right.
#
# So the reference is **the newest image that was actually built and pushed** for
# each service. If a build produced an image and the host is not running it, that
# is drift by any reading. If no build ran, there is nothing to be behind.
#
# ## Why `behind` and `unknown` are not the same word
#
# An image the check cannot place is not an image it has placed one commit back.
# The first means this script is partly blind — an image from before
# kolonie-platform#75, or a revision GHCR no longer lists — and the second is a
# host that needs a deploy. Reporting them identically is how a check becomes
# noise: the reader learns that half the report means nothing, and then treats
# all of it that way.
#
# **It never deploys anything.** Detecting drift and correcting it are different
# decisions, and the second one needs the maintainer (AGENTS.md §8).
#
# Exit status: 0 when every service is current, 1 otherwise. A non-zero exit
# means the host, not the script — a failure of this script's own is exit 2.

set -uo pipefail

ORG="${KOLONIE_ORG:-Kolonie-AI}"

# The one list of what this organisation builds images for (`#107`).
#
# Sourced rather than restated, which is the whole of `#149`: this file kept its
# own copy of the list and the copy was two services short. `services.sh` exists
# because that had already happened once, between `pin-report.sh` and
# `deployed-revision.sh`, and the two services missing from that copy were the
# same two — `support-triage-runner` and `badge-runner`.
# shellcheck source=scripts/services.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/services.sh"

# Which GHCR package holds each service's images.
#
# **Derived, and the earlier reasoning for stating it is answered rather than
# overruled.** That argument was: *a service whose package is renamed should
# break loudly here rather than report `unknown` forever.* It still holds, and a
# derived name gives it — a package that is not there is `GHCR refused the
# request` with GitHub's own words attached, which is loud and says why. What the
# stated list gave instead was the silent half: a service nobody added fell to
# the empty case and reported *no GHCR package is mapped*, which reads as a gap
# at GHCR and was a `case` statement in this file. Measured on `#147`, where two
# of six rows said exactly that while both services were running a labelled
# revision on the host.
#
# **The empty answer stays, and now means something.** A service that is not one
# of ours is a row the probe produced that this organisation does not build, and
# that is worth saying rather than guessing a package name for.
package_for() {
    local known
    for known in "${KOLONIE_SERVICES[@]}"; do
        [ "$known" = "$1" ] && { echo "kolonie-$1"; return; }
    done

    echo ""
}

# Every commit sha this package has been tagged with, newest build first.
#
# `latest` and the digest-only versions are dropped: the first is a mutable
# pointer and the second is an untagged layer. What is left is the build history
# in order, which is what turns "not the newest" into "three builds behind".
#
# A non-zero return means GHCR could not be asked, which is never the same as a
# package with no builds and must never be read as "no drift" — an outage at
# GitHub reported that way is exactly the reassuring silence this workflow exists
# to end.
#
# Returns 1 when GHCR refused the request and 2 when it answered with no
# tagged build. Both end as `unknown`, but they are different faults and the
# report has to say which: the first is something about the request the caller
# can act on, the second is a package nothing has pushed to. Collapsing them
# sends the reader looking for a build that exists.
#
# **A refusal leaves its reason in GHCR_ERROR** (#50). The first version sent
# gh's stderr to /dev/null and reported only that the call had failed, which
# reproduced the mistake #43 exists to correct one level up: the state without
# the reason. It cost a wrong diagnosis immediately — a run reported
# `moderation-runner | unknown` and the issue filed off it named a per-package
# permission, inferred from an exit code rather than read from an error. Whatever
# the cause turns out to be, the next reader should not have to infer it.
#
# gh prints the status line and the API's message here; neither carries a token.
sha_history() {
    local pkg="$1" raw
    # `</dev/null` for the reason health-report.sh documents: this runs inside a
    # `while read` loop over stdin, and a subprocess that inherits that stdin
    # eats the remaining rows. The report then covers one service and looks
    # complete.
    # The reason goes to a **file**, not a variable. This function is called
    # through a command substitution, so it runs in a subshell and anything it
    # assigns dies with that subshell — the same trap health-report.sh documents
    # for its own loop. The file outlives it; `2>` truncates it per call, so a
    # stale reason cannot be attributed to the next package.
    raw=$(gh api --paginate "/orgs/${ORG}/packages/container/${pkg}/versions?per_page=100" \
            --jq '.[] | .metadata.container.tags[]?' 2>"$ERR_FILE" </dev/null) || return 1
    printf '%s\n' "$raw" | grep -E '^[0-9a-f]{40}$' || return 2
}

summary=""
fingerprint_input=""
why=""
reason=""
ghcr_status=0

# Somewhere to catch gh's stderr. A file rather than a command substitution
# because the exit status of the call is what decides the branch, and wrapping it
# to capture both would lose it.
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT
verdict="ok"
exit_code=0
rows=0

while IFS=$'\t' read -r svc revision image; do
    [ -z "${svc:-}" ] && continue
    rows=$((rows + 1))

    pkg="$(package_for "$svc")"
    if [ -z "$pkg" ]; then
        summary="$summary
| \`$svc\` | unknown | no GHCR package is mapped to this service |"
        [ "$verdict" = "ok" ] && verdict="unknown"
        continue
    fi

    history="$(sha_history "$pkg")"; ghcr_status=$?
    if [ "$ghcr_status" -ne 0 ] || [ -z "$history" ]; then
        if [ "$ghcr_status" -eq 1 ]; then
            # One line, trimmed: the useful part is the status and the message,
            # and gh follows them with a usage block nobody needs in a table.
            reason=$(tr '\n' ' ' < "$ERR_FILE" | sed 's/  */ /g; s/^ *//; s/ *$//' | cut -c1-300)
            why="GHCR refused the request for \`$pkg\`: ${reason:-no error text}"
        else
            why="GHCR lists no tagged build for \`$pkg\`"
        fi
        summary="$summary
| \`$svc\` | unknown | $why |"
        [ "$verdict" = "ok" ] && verdict="unknown"
        continue
    fi

    newest="$(printf '%s\n' "$history" | head -1)"

    if [ "$revision" = "-" ]; then
        # No label. Every image built before kolonie-platform#75 is here, and so
        # is a container that is not running at all.
        summary="$summary
| \`$svc\` | unknown | the running image carries no revision label |"
        [ "$verdict" = "ok" ] && verdict="unknown"
        continue
    fi

    if [ "$revision" = "$newest" ]; then
        summary="$summary
| \`$svc\` | current | \`${revision:0:7}\` |"
        continue
    fi

    # Not the newest. Placing it in the build history turns that into a number,
    # and failing to place it is a different answer.
    position="$(printf '%s\n' "$history" | grep -nxF "$revision" | head -1 | cut -d: -f1)"
    if [ -z "$position" ]; then
        summary="$summary
| \`$svc\` | unknown | running \`${revision:0:7}\`, which GHCR does not list for \`$pkg\` |"
        [ "$verdict" = "ok" ] && verdict="unknown"
        continue
    fi

    behind=$((position - 1))
    summary="$summary
| \`$svc\` | **behind by $behind** | running \`${revision:0:7}\`, newest is \`${newest:0:7}\` |"
    fingerprint_input="$fingerprint_input$svc:$revision:$newest
"
    verdict="drifted"
    exit_code=1
done

if [ "$rows" -eq 0 ]; then
    # No rows at all is a broken probe, not a current host. Exit 2 so the caller
    # can tell "this script could not run" from "the host is behind".
    echo "The revision probe returned no rows."
    echo "VERDICT=unknown" >&2
    echo "FINGERPRINT=no-rows" >&2
    exit 2
fi

# Three verdicts, three headings. `unknown` claiming the host is behind would be
# the check asserting the one thing it just said it could not determine — and a
# reader who acts on that finds nothing wrong and stops believing the next one.
case "$verdict" in
    ok)      printf 'Every service is running the newest image built for it.\n\n' ;;
    drifted) printf 'The host is not serving what was last built for it.\n\n' ;;
    *)       printf 'Some services could not be placed against what was last built.\n\n' ;;
esac

printf '| Service | State | Detail |\n|---|---|---|%s\n' "$summary"

if [ "$verdict" = "drifted" ]; then
    printf '\nThis reports; it does not deploy. Correcting drift is a separate decision\n'
    printf '(`AGENTS.md` §8) — a re-run of the deploy for the affected service is the\n'
    printf 'usual answer, but a service that is behind because its deploy *failed* needs\n'
    printf 'the reason before the retry.\n'
fi

# The fingerprint covers what is behind and what it should be, so a host that has
# been one build behind for six hours produces the same digest every run and the
# caller stays quiet. A second service falling behind changes it, which is the
# change worth a comment. `unknown` rows are deliberately excluded: they do not
# change between runs and would pin the fingerprint against ever going quiet.
if [ -n "$fingerprint_input" ]; then
    fp="$(printf '%s' "$fingerprint_input" | sort | sha256sum | cut -c1-16)"
else
    fp="$verdict"
fi

echo "VERDICT=$verdict" >&2
echo "FINGERPRINT=$fp" >&2
exit "$exit_code"
