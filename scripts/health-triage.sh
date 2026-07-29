#!/bin/bash
# Kolonie AI — turn a health report into a verdict (#11)
#
# Reads the rows scripts/health-report.sh produces on stdin and decides whether
# anything is wrong. Separate from both the report and the workflow on purpose:
# it is the part with a judgement in it, so it is the part that has to be
# testable without a Docker daemon and without a deploy host. Pipe it rows and
# check what it says.
#
#   ./scripts/health-report.sh | ./scripts/health-triage.sh
#
# Writes a markdown summary to stdout, and two machine-readable lines to stderr:
#
#   VERDICT=ok|degraded
#   FINGERPRINT=<stable digest of what is wrong>
#
# The fingerprint is what keeps a watcher quiet. A stack that has been broken in
# the same way for six hours produces the same fingerprint every run, so the
# caller can tell "still wrong" from "wrong in a new way" and comment only on the
# second. An alert channel that repeats itself every fifteen minutes is one
# people mute, and a muted alert is worse than none — it looks like coverage.
#
# Exit status: 0 if everything is healthy, 1 if anything is not. Nothing here
# fails on its own account; a non-zero exit means the stack, not the script.

set -uo pipefail

# How long a container has to have been failing before it is called sustained
# rather than a blip. Fifteen minutes is three failing checks at the 30s interval
# every service in docker-compose.yml uses, plus room for a restart to settle.
#
# It changes the wording, not whether the thing is reported. kolonie-website sat
# unhealthy for days, so under-reporting is the failure mode that has actually
# happened here; a container unhealthy for two minutes is still reported, just
# not described as chronic.
SUSTAINED_SECONDS="${SUSTAINED_SECONDS:-900}"

# Seconds into something a person reads without counting zeroes. The distinction
# that matters is minutes versus days, so the units are coarse deliberately.
human() {
    local s="${1:-0}"
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        echo "$((s / 60))m"
    elif [ "$s" -lt 86400 ]; then
        echo "$((s / 3600))h"
    else
        echo "$((s / 86400))d"
    fi
}

healthy=()
problems=()
fingerprint_parts=()

while IFS=$'\t' read -r name state health streak approx image; do
    [ -z "${name:-}" ] && continue
    [ "$name" = "NO_CONTAINERS" ] && {
        problems+=("| _none running_ | - | - | - | the host reports no containers at all |")
        fingerprint_parts+=("no-containers")
        continue
    }

    duration="$(human "$approx")"

    if [ "$state" = "gone" ]; then
        problems+=("| \`$name\` | gone | - | - | named in the project, not present on the host |")
        fingerprint_parts+=("$name:gone")
    elif [ "$state" != "running" ]; then
        problems+=("| \`$name\` | $state | - | - | not running |")
        fingerprint_parts+=("$name:$state")
    elif [ "$health" = "unhealthy" ]; then
        if [ "${approx:-0}" -ge "$SUSTAINED_SECONDS" ]; then
            note="unhealthy for about $duration — sustained, not a blip"
        else
            note="unhealthy for about $duration"
        fi
        problems+=("| \`$name\` | running | unhealthy | $streak | $note |")
        fingerprint_parts+=("$name:unhealthy")
    else
        healthy+=("$name ($health)")
    fi
done

if [ "${#problems[@]}" -eq 0 ]; then
    echo "All containers are running and none reports itself unhealthy."
    echo
    for entry in "${healthy[@]}"; do echo "- $entry"; done
    echo "VERDICT=ok" >&2
    echo "FINGERPRINT=ok" >&2
    exit 0
fi

echo "| Container | State | Health | Failing checks | Note |"
echo "|---|---|---|---|---|"
for row in "${problems[@]}"; do echo "$row"; done

if [ "${#healthy[@]}" -gt 0 ]; then
    echo
    echo "<details><summary>Healthy (${#healthy[@]})</summary>"
    echo
    for entry in "${healthy[@]}"; do echo "- $entry"; done
    echo
    echo "</details>"
fi

echo
echo "A container can serve every request correctly and still report itself"
echo "unhealthy — that is the case this watcher exists for, and an external HTTP"
echo "probe does not see it. Check the container's own health log before assuming"
echo "the service is down:"
echo
echo '```'
echo "docker inspect <container> --format '{{json .State.Health}}'"
echo '```'

# Sorted so the same set of problems in a different order is the same
# fingerprint. Without that, two unhealthy containers would look like a new
# situation whenever the daemon happened to list them the other way round.
echo "VERDICT=degraded" >&2
printf 'FINGERPRINT=%s\n' "$(printf '%s\n' "${fingerprint_parts[@]}" | sort | tr '\n' ',' | sed 's/,$//')" >&2

exit 1
