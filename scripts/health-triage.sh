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

# When a daily backup has been silent long enough to be a fault rather than a
# late run. 36 hours is one missed run plus the timer's jitter plus room for a
# reboot: a backup that ran yesterday at 03:00 and has not run today by 15:00 is
# genuinely overdue, and anything tighter would cry wolf on the morning after an
# outage — which is the morning the report most needs to be believed.
BACKUP_STALE_SECONDS="${BACKUP_STALE_SECONDS:-129600}"

# How full the Docker partition may get before it is reported (#37).
#
# 85% is a threshold with room to act in it rather than an alarm at the moment
# of failure: a partition that crosses it has days left at ordinary growth, and
# a report that only fires at 99% arrives after the host has already stopped
# being able to write. Capped container logs bound the fastest way this fills;
# images, volumes and the Postgres data directory are not bounded by anything.
DISK_FULL_PERCENT="${DISK_FULL_PERCENT:-85}"

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

# `problems` drives the table and the exit status; these two only decide which
# closing advice is printed. A container fault and a late backup are diagnosed
# in completely different places, and a report that offers both every time is
# one the reader stops reading.
container_problems=()
backup_problems=()
disk_problems=()

while IFS=$'\t' read -r name state health streak approx image; do
    [ -z "${name:-}" ] && continue
    [ "$name" = "NO_CONTAINERS" ] && {
        problems+=("| _none running_ | - | - | - | the host reports no containers at all |")
        container_problems+=("$name")
        fingerprint_parts+=("no-containers")
        continue
    }

    duration="$(human "$approx")"

    # The backup row is not a container, so it is judged before the container
    # rules — `state=ok` would otherwise fall through to "not running" and read
    # as a broken service. What is being asked here is one question: has a
    # backup succeeded recently enough that the ledger could be recovered.
    if [ "$name" = "backup" ]; then
        if [ "$state" = "never" ]; then
            problems+=("| _database backup_ | never | - | - | no backup has ever succeeded on this host |")
            backup_problems+=("never")
            fingerprint_parts+=("backup:never")
        elif [ "${approx:-0}" -ge "$BACKUP_STALE_SECONDS" ]; then
            problems+=("| _database backup_ | stale | - | - | last successful backup was $duration ago |")
            backup_problems+=("stale")
            fingerprint_parts+=("backup:stale")
        else
            healthy+=("database backup ($duration ago)")
        fi
        continue
    fi

    # Not a container either, and judged before the container rules for the same
    # reason the backup row is: `state=ok` would otherwise fall through to "not
    # running" and read as a broken service. APPROX_SECONDS carries a percentage
    # here, not a duration — see health-report.sh.
    if [ "$name" = "disk" ]; then
        if [ "$state" = "unknown" ]; then
            problems+=("| _disk_ | unknown | - | - | the host could not report how full its partition is |")
            disk_problems+=("unknown")
            fingerprint_parts+=("disk:unknown")
        elif [ "${approx:-0}" -ge "$DISK_FULL_PERCENT" ]; then
            problems+=("| _disk_ | filling | - | - | the Docker partition is ${approx}% full |")
            disk_problems+=("full")
            # The percentage is deliberately out of the fingerprint. It moves a
            # point at a time, and including it would file a fresh comment on
            # every run while the condition simply persists.
            fingerprint_parts+=("disk:full")
        else
            healthy+=("disk (${approx}% used)")
        fi
        continue
    fi

    if [ "$state" = "gone" ]; then
        problems+=("| \`$name\` | gone | - | - | named in the project, not present on the host |")
        container_problems+=("$name")
        fingerprint_parts+=("$name:gone")
    elif [ "$state" != "running" ]; then
        problems+=("| \`$name\` | $state | - | - | not running |")
        container_problems+=("$name")
        fingerprint_parts+=("$name:$state")
    elif [ "$health" = "unhealthy" ]; then
        if [ "${approx:-0}" -ge "$SUSTAINED_SECONDS" ]; then
            note="unhealthy for about $duration — sustained, not a blip"
        else
            note="unhealthy for about $duration"
        fi
        problems+=("| \`$name\` | running | unhealthy | $streak | $note |")
        container_problems+=("$name")
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

# Only when a container is actually implicated. A late backup is not diagnosed
# by inspecting a container's health log, and advice that does not apply to the
# problem on screen teaches the reader to skip the prose.
if [ "${#container_problems[@]}" -gt 0 ]; then
    echo
    echo "A container can serve every request correctly and still report itself"
    echo "unhealthy — that is the case this watcher exists for, and an external HTTP"
    echo "probe does not see it. Check the container's own health log before assuming"
    echo "the service is down:"
    echo
    echo '```'
    echo "docker inspect <container> --format '{{json .State.Health}}'"
    echo '```'
fi

if [ "${#backup_problems[@]}" -gt 0 ]; then
    echo
    echo "The backup is a systemd timer on the host, not a container — a stack that"
    echo "is entirely healthy can have had no backup for a week. Start here:"
    echo
    echo '```'
    echo "systemctl status kolonie-backup.timer"
    echo "journalctl -u kolonie-backup.service -n 50"
    echo "/opt/kolonie/scripts/backup.sh verify"
    echo '```'
fi

if [ "${#disk_problems[@]}" -gt 0 ]; then
    echo
    echo "A full partition takes every service down at once, and for a reason none of"
    echo "their logs can record — there is nowhere left to record it. Container logs"
    echo "are capped in docker-compose.yml (#37); everything else on this disk is not."
    echo "Find what grew before deleting anything:"
    echo
    echo '```'
    echo "df -h /var/lib/docker"
    echo "docker system df"
    echo "sudo du -xh --max-depth=1 /var/lib/docker | sort -h | tail"
    echo '```'
    echo
    echo "\`docker system prune\` removes stopped containers and unused images. It also"
    echo "removes the image a rollback would return to, so read \`state/deployed.env\`"
    echo "first and keep what it names."
fi

# Sorted so the same set of problems in a different order is the same
# fingerprint. Without that, two unhealthy containers would look like a new
# situation whenever the daemon happened to list them the other way round.
echo "VERDICT=degraded" >&2
printf 'FINGERPRINT=%s\n' "$(printf '%s\n' "${fingerprint_parts[@]}" | sort | tr '\n' ',' | sed 's/,$//')" >&2

exit 1
