#!/bin/bash
# Kolonie AI — does the host disagree with its own deploy record? (#89)
#
# Reads the rows scripts/pin-report.sh produces on stdin and decides whether the
# running containers and `state/deployed.env` are telling the same story.
# Separate from the probe for the reason health-triage.sh and drift-triage.sh
# are: this is the part with a judgement in it, so it is the part that has to be
# testable without a deploy host.
#
#   ./scripts/pin-report.sh | ./scripts/pin-triage.sh
#
# Writes a markdown summary to stdout, and two machine-readable lines to stderr:
#
#   VERDICT=ok|drifted|unknown
#   FINGERPRINT=<stable digest of what disagrees>
#
# ## The four states, and why `absent` is not `drifted`
#
# | State | What it means |
# |---|---|
# | `pinned` | The container is running the image the record names |
# | `drifted` | It is running a **different** image, and nothing said so |
# | `absent` | The container is not running at all |
# | `unknown` | The record names nothing, or names an image this host does not hold |
#
# A service that is not running is Health Watch's question, and it already has an
# issue and a verdict of its own. Calling it drift here would file a second
# report for one fault and make both of them harder to read — the mistake this
# repository's own comment on the drift lane warns against, one lane over.
#
# `unknown` is likewise not `ok`. A host with no `deployed.env` has never
# completed a pinned deploy, and an image the store cannot resolve is this check
# admitting it is blind rather than reporting agreement. Reporting either as fine
# is how a watcher becomes noise: the reader learns that half the report means
# nothing and then treats all of it that way.
#
# **It never deploys, pulls or restarts anything.** Detecting drift and
# correcting it are different decisions, and the second one needs the maintainer
# (AGENTS.md §8). The correction here is `./scripts/rollback.sh`, which returns
# the stack to the digests in the very record this script compares against.
#
# Exit status: 0 when nothing disagrees, 1 when something does. A failure of this
# script's own — no rows at all — is exit 2, because a probe that produced
# nothing is a broken watcher and must never read as a clean host.

set -uo pipefail

summary=""
fingerprint_input=""
verdict="ok"
exit_code=0
rows=0
drifted=0
unknown=0
absent=0
pinned=0

short() {
    # A local image id is `sha256:` and 64 hex characters, which is unreadable in
    # a table and identifying in twelve. The full value stays in the fingerprint,
    # so nothing that distinguishes two runs is lost by shortening the display.
    local v="$1"
    [ "$v" = "-" ] && { printf '%s' "—"; return; }
    printf '%s' "${v#sha256:}" | cut -c1-12
}

while IFS=$'\t' read -r svc recorded_ref recorded_id running_id; do
    [ -z "${svc:-}" ] && continue
    rows=$((rows + 1))

    state=""
    note=""

    if [ "${running_id:--}" = "-" ]; then
        state="absent"
        note="the container is not running — Health Watch's question, not this one"
        absent=$((absent + 1))
    elif [ "${recorded_ref:--}" = "-" ]; then
        state="unknown"
        note="\`state/deployed.env\` names no image for this service"
        unknown=$((unknown + 1))
    elif [ "${recorded_id:--}" = "-" ]; then
        state="unknown"
        note="the recorded image is not in this host's image store"
        unknown=$((unknown + 1))
    elif [ "$recorded_id" = "$running_id" ]; then
        state="pinned"
        note="running what the record names"
        pinned=$((pinned + 1))
    else
        state="drifted"
        note="**running something the record does not name**"
        drifted=$((drifted + 1))
        # Only disagreement goes into the fingerprint. A host that is fine has
        # nothing to be identified by, and including the healthy rows would make
        # the fingerprint change every time an unrelated service was redeployed
        # — turning "what is wrong has changed" into a comment every quarter hour.
        fingerprint_input="${fingerprint_input}${svc}=${recorded_id}/${running_id};"
    fi

    summary="${summary}| \`${svc}\` | ${state} | \`$(short "${recorded_id:-}")\` | \`$(short "${running_id:-}")\` | ${note} |
"
done

if [ "$rows" -eq 0 ]; then
    echo "The pin report produced no rows. That is a broken probe, not a clean host." >&2
    echo "VERDICT=unknown" >&2
    echo "FINGERPRINT=" >&2
    exit 2
fi

if [ "$drifted" -gt 0 ]; then
    verdict="drifted"
    exit_code=1
elif [ "$unknown" -gt 0 ]; then
    verdict="unknown"
    exit_code=1
fi

fingerprint=$(printf '%s' "$fingerprint_input" | sha256sum | cut -c1-16)

{
    if [ "$verdict" = "drifted" ]; then
        printf '**%d of %d services are running an image `state/deployed.env` does not name.**\n\n' \
            "$drifted" "$rows"
        printf 'The record is what `rollback.sh` returns the stack to and what every\n'
        printf 'report of "what is deployed" quotes. While this disagreement stands, that\n'
        printf 'file is fiction and anything reading it is wrong in the same direction.\n\n'
    elif [ "$verdict" = "unknown" ]; then
        printf '**This check could not place %d of %d services.**\n\n' "$unknown" "$rows"
        printf 'Not a report that the host is behind — a report that this check is partly\n'
        printf 'blind, which is a different thing and fixed differently.\n\n'
    else
        printf 'Every running container matches the image `state/deployed.env` names.\n\n'
    fi

    printf '| Service | State | Recorded | Running | |\n'
    printf '|---|---|---|---|---|\n'
    printf '%s' "$summary"

    if [ "$absent" -gt 0 ]; then
        printf '\n%d service(s) are not running. That is not drift and is not counted as any.\n' "$absent"
    fi

    printf '\nThis reports; it does not deploy. The correction is `./scripts/rollback.sh`,\n'
    printf 'which returns the stack to the digests in the record above — and it is a\n'
    printf "person's decision to run it, not a watcher's.\n"
}

echo "VERDICT=${verdict}" >&2
echo "FINGERPRINT=${fingerprint}" >&2

exit "$exit_code"
