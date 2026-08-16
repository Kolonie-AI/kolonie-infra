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
# ## Why a service behind by one is not reported for the first three quarters of an hour
#
# Between a push to `kolonie-platform` and the host running the image built from
# it there is a build, a push to GHCR and a deploy — and the image reaches GHCR
# **first**. So for the whole remainder of that chain the newest image exists and
# the host is not running it, which is precisely the condition above. A watch on a
# fifteen-minute cron cannot miss it, and did not: nineteen self-closing drift
# reports in six days, mean lifetime about an hour, not one of them a state
# anybody acted on (`#193`). The last of them was filed six seconds before the
# deploy it was describing finished (`#191`).
#
# So a service is behind if it is not running the newest image **and that image
# has had time to be deployed** — `KOLONIE_DRIFT_GRACE_MINUTES`, 45 by default.
# An image younger than that is reported as a deploy in flight: it appears in the
# table, it does not open an issue, and the run still exits 0.
#
# The failure mode of a noisy alarm is not the noise. It is the twentieth report,
# which is real, arriving in the shape the previous nineteen taught the reader to
# skim.
#
# **The window delays; it does not hide.** A deploy that failed leaves the host
# behind an image that keeps ageing, so the next run past the window files exactly
# as it does today. What is lost is at most 45 minutes of notice on a fault whose
# own correction needs the maintainer anyway.
#
# The verdict stays `ok` while something is in flight rather than gaining a fourth
# word, because `health-watch.yml` branches on `drifted` against everything else
# and a deploy in progress belongs on the same side of that line as a current
# host. Only the heading changes, so a person reading the run is not told
# everything is current when something is mid-rollout.
#
# **It never deploys anything.** Detecting drift and correcting it are different
# decisions, and the second one needs the maintainer (AGENTS.md §8).
#
# Exit status: 0 when every service is current, 1 otherwise. A non-zero exit
# means the host, not the script — a failure of this script's own is exit 2.

set -uo pipefail

ORG="${KOLONIE_ORG:-Kolonie-AI}"

# How long an image is allowed to exist before the host is expected to be running
# it (`#193`). Overridable so a rehearsal can pin it, and so a deploy that gets
# slower has one number to change rather than a script to edit.
#
# 45 minutes is chosen against the measurement rather than picked: of the nineteen
# reports that closed themselves, the longest-lived ordinary one was 77 minutes
# and the median was under an hour, but every one of those lifetimes is a *cron
# lag* — the drift ended when the next quarter-hour run noticed. The build and
# deploy itself takes single-digit minutes. 45 covers a rollout that goes slowly,
# a queued runner and a missed cron tick, and still files inside the hour on a
# host that is genuinely stuck.
GRACE_MINUTES="${KOLONIE_DRIFT_GRACE_MINUTES:-45}"

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

# Every commit sha this package has been tagged with, newest build first, each
# with the time GHCR recorded for that version: `<sha>\t<created_at>`.
#
# The timestamp is what the grace window is measured against (`#193`), and it
# comes from the call that was already being made — `versions` carries
# `created_at` per version, so knowing how old the newest image is costs nothing
# and needs no second endpoint. A cross-repository question to `kolonie-platform`
# about whether a deploy is running would be the more precise one and was
# rejected for that: this script's value is that it answers from GHCR and the host
# alone.
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
            --jq '.[] | .created_at as $at | .metadata.container.tags[]? | "\(.)\t\($at)"' \
            2>"$ERR_FILE" </dev/null) || return 1
    printf '%s\n' "$raw" | grep -E '^[0-9a-f]{40}	' || return 2
}

# How many minutes ago GHCR says this version was created, or the empty string if
# that cannot be worked out.
#
# Empty is deliberately **not** treated as young. A timestamp this script cannot
# read is a thing it does not know, and the safe direction for an unknown here is
# the one that still reports: staying quiet on an age nobody established is how
# the window would turn from a delay into a silence.
minutes_since() {
    local at="$1" then now
    [ -n "$at" ] || return 0
    then=$(date -u -d "$at" +%s 2>/dev/null) || return 0
    now=$(date -u +%s)
    [ "$then" -le "$now" ] || { echo 0; return 0; }
    echo $(((now - then) / 60))
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
in_flight=0

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

    # Parameter expansion rather than `printf | head -1`, and the reason is not
    # tidiness (#163). `head` exits after the first line; if `history` is longer
    # than the pipe buffer — a package with a few thousand tags is — `printf` is
    # still writing when the reader goes away, and bash prints
    # `printf: write error: Broken pipe` **to stderr**. Stderr is this script's
    # verdict channel, the workflow appends it to `$GITHUB_OUTPUT`, and
    # `$GITHUB_OUTPUT` refuses a file with a non-`KEY=value` line in it. One
    # broken pipe therefore killed a step that had nothing to report but good
    # news. `verdict-out.sh` now filters the channel as well; this removes the
    # thing that needed filtering.
    newest_row="${history%%$'\n'*}"
    newest="${newest_row%%$'\t'*}"
    # The shas alone, for placing the running revision in the history below.
    shas="$(cut -f1 <<< "$history")"

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
    # `-m1` rather than `| head -1`, for the reason above: `head` closing the
    # pipe is what raises the broken pipe, and `grep` stopping itself after the
    # first match is the same answer with no reader to go away. A here-string
    # rather than `printf |` for the same reason on the other side.
    position="$(grep -nxF -m1 "$revision" <<< "$shas" | cut -d: -f1)"
    if [ -z "$position" ]; then
        summary="$summary
| \`$svc\` | unknown | running \`${revision:0:7}\`, which GHCR does not list for \`$pkg\` |"
        [ "$verdict" = "ok" ] && verdict="unknown"
        continue
    fi

    behind=$((position - 1))

    # Inside the grace window this is a rollout, not a fault (`#193`). It stays in
    # the table — a reader looking at the run should see what is moving — and it
    # is kept out of the fingerprint and out of the exit status, which are the two
    # things that open an issue.
    #
    # Measured against the **oldest build this service is missing**, not against
    # the newest one. They are the same image for a service behind by one, which
    # is what a rollout looks like. They are not the same for a service behind by
    # three: there the newest image may be minutes old and the host still missed
    # two deploys hours ago, and excusing that on the age of the newest would be
    # the window hiding a fault rather than delaying a report of one.
    missing_row="$(sed -n "$((position - 1))p" <<< "$history")"
    age="$(minutes_since "${missing_row#*$'\t'}")"
    if [ -n "$age" ] && [ "$age" -lt "$GRACE_MINUTES" ]; then
        summary="$summary
| \`$svc\` | deploy in flight | running \`${revision:0:7}\`, newest is \`${newest:0:7}\`, built $age min ago |"
        in_flight=$((in_flight + 1))
        continue
    fi

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
    ok)
        if [ "$in_flight" -gt 0 ]; then
            printf 'A deploy is in flight. Nothing is behind for longer than a rollout takes.\n\n'
        else
            printf 'Every service is running the newest image built for it.\n\n'
        fi
        ;;
    drifted) printf 'The host is not serving what was last built for it.\n\n' ;;
    *)       printf 'Some services could not be placed against what was last built.\n\n' ;;
esac

printf '| Service | State | Detail |\n|---|---|---|%s\n' "$summary"

if [ "$in_flight" -gt 0 ]; then
    printf '\n`deploy in flight` is a service where the oldest build it has not got is less\n'
    printf 'than %s minutes old — the image reaches GHCR before it reaches the host, so\n' "$GRACE_MINUTES"
    printf 'this is what the middle of an ordinary rollout looks like (`#193`). It is not\n'
    printf 'reported as drift and opens nothing. A deploy that failed leaves that image\n'
    printf 'ageing, and the run past the window reports it as behind.\n'
fi

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
