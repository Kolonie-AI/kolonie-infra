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

# The timer is weekly with up to thirty minutes of jitter. Eight days allows a
# delayed watcher or reboot catch-up without letting a missed weekly run hide.
IMAGE_PRUNE_STALE_SECONDS="${IMAGE_PRUNE_STALE_SECONDS:-691200}"

# How little memory may remain immediately available before it is a fault
# (#101). 20% means roughly 1.6 GiB on the measured 7.8 GiB host. On 2026-08-09
# it had 6.1 GiB available (78%), leaving a wide healthy margin while still
# reporting pressure early enough to identify a growing process before OOM.
MEMORY_AVAILABLE_PERCENT="${MEMORY_AVAILABLE_PERCENT:-20}"

# How full the Docker partition's inode table may get (#101). The host measured
# 7% on 2026-08-09; 85% therefore cannot fire on its ordinary small-file load
# and leaves the same intervention margin as the byte-capacity alarm.
INODE_FULL_PERCENT="${INODE_FULL_PERCENT:-85}"

# Average load over health-report.sh's one-hour window, expressed as a percentage
# of online cores (#101). 100% means one runnable task per core for the sustained
# window: saturation rather than a spike. The measured host was at 0.73 on four
# cores on 2026-08-09 (18%), well clear of this threshold.
LOAD_SUSTAINED_PERCENT="${LOAD_SUSTAINED_PERCENT:-100}"

# How few messages the Twilio balance may be worth before it is a problem (#83).
#
# **Expressed in messages remaining at the most expensive allowed destination,
# not in dollars**, because a dollar figure means something different every time
# the allowlist changes. health-report.sh does that conversion and hands this a
# count.
#
# **Two hundred, because that is one day at the global daily cap.** The cap in
# `.env.example` §Twilio is 200 messages in 24 hours, so this fires when there is
# less than a full day of maximum sending left — which is a morning to act in
# rather than a discovery. Measured 2026-08-05: the balance was $48.84 and DE, the
# dearest destination on the default list, is $0.112, so roughly 436 messages —
# comfortably above this and exactly why it will otherwise be forgotten.
SMS_LOW_MESSAGES="${SMS_LOW_MESSAGES:-200}"

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

human_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", units, " ")
        value = bytes + 0; unit = 1
        while (value >= 1024 && unit < 5) { value /= 1024; unit++ }
        if (unit == 1) printf "%d %s", value, units[unit]
        else printf "%.1f %s", value, units[unit]
    }'
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
prune_problems=()
memory_problems=()
inode_problems=()
load_problems=()
oom_problems=()
sms_problems=()
timer_problems=()
# Units whose file on the host does not match this repository's (#126).
unit_problems=()

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
        elif [ "$state" = "partial" ]; then
            problems+=("| _disk_ | partial | - | - | the partition is ${approx}% full, but Docker did not report reclaimable image storage |")
            disk_problems+=("image-storage-unknown")
            fingerprint_parts+=("disk:image-storage-unknown")
        elif [ "${approx:-0}" -ge "$DISK_FULL_PERCENT" ]; then
            problems+=("| _disk_ | filling | - | - | the Docker partition is ${approx}% full |")
            disk_problems+=("full")
            # The percentage is deliberately out of the fingerprint. It moves a
            # point at a time, and including it would file a fresh comment on
            # every run while the condition simply persists.
            fingerprint_parts+=("disk:full")
        else
            healthy+=("disk (${approx}% used; $(human_bytes "$streak") of $(human_bytes "$image") in images reclaimable)")
        fi
        continue
    fi

    if [ "$name" = "image-prune" ]; then
        if [ "$state" = "missing" ]; then
            problems+=("| _image prune_ | missing | - | - | the weekly timer is not installed on the host |")
            prune_problems+=("missing")
            fingerprint_parts+=("image-prune:missing")
        elif [ "$state" = "failed" ]; then
            problems+=("| _image prune_ | failed | - | - | the timer ran, but its service failed |")
            prune_problems+=("failed")
            fingerprint_parts+=("image-prune:failed")
        elif [ "$state" = "never" ]; then
            problems+=("| _image prune_ | never | - | - | the timer is installed, but no successful prune has been recorded |")
            prune_problems+=("never")
            fingerprint_parts+=("image-prune:never")
        elif [ "${approx:-0}" -ge "$IMAGE_PRUNE_STALE_SECONDS" ]; then
            problems+=("| _image prune_ | stale | - | - | the last successful prune was $duration ago |")
            prune_problems+=("stale")
            fingerprint_parts+=("image-prune:stale")
        else
            healthy+=("image prune ($duration ago; $(human_bytes "$streak") freed)")
        fi
        continue
    fi

    # These host-resource rows borrow the container columns in documented ways
    # so the report remains a stable six-column stream. Judge them before the
    # container rules, as with disk and backup.
    if [ "$name" = "memory" ]; then
        if [ "$state" = "unknown" ]; then
            problems+=("| _memory_ | unknown | - | - | the host could not read MemAvailable |")
            memory_problems+=("unknown")
            fingerprint_parts+=("memory:unknown")
        elif [ "${approx:-0}" -le "$MEMORY_AVAILABLE_PERCENT" ]; then
            problems+=("| _memory_ | low | - | - | ${approx}% available (${streak} of ${image} KiB) |")
            memory_problems+=("low")
            fingerprint_parts+=("memory:low")
        else
            healthy+=("memory (${approx}% available; ${streak} of ${image} KiB)")
        fi
        continue
    fi

    if [ "$name" = "inodes" ]; then
        if [ "$state" = "unknown" ]; then
            problems+=("| _inodes_ | unknown | - | - | the host could not report inode use |")
            inode_problems+=("unknown")
            fingerprint_parts+=("inodes:unknown")
        elif [ "${approx:-0}" -ge "$INODE_FULL_PERCENT" ]; then
            problems+=("| _inodes_ | filling | - | - | ${image} is ${approx}% full by inode count |")
            inode_problems+=("full")
            fingerprint_parts+=("inodes:full")
        else
            healthy+=("inodes (${approx}% used on ${image})")
        fi
        continue
    fi

    if [ "$name" = "load" ]; then
        load_window="$(human "${streak:-0}")"
        if [ "$state" = "unknown" ]; then
            problems+=("| _processor load_ | unknown | - | - | sysstat has no readable load data for the ${load_window} window |")
            load_problems+=("unknown")
            fingerprint_parts+=("load:unknown")
        elif [ "${approx:-0}" -ge "$LOAD_SUSTAINED_PERCENT" ]; then
            problems+=("| _processor load_ | saturated | - | - | ${image} over ${load_window} on ${health} cores (${approx}% of capacity) |")
            load_problems+=("saturated")
            fingerprint_parts+=("load:saturated")
        else
            healthy+=("load (${image} over ${load_window} on ${health} cores; ${approx}% of capacity)")
        fi
        continue
    fi

    if [ "$name" = "oom" ]; then
        if [ "$state" = "unknown" ]; then
            problems+=("| _OOM kills_ | unknown | - | - | the kernel journal could not be read |")
            oom_problems+=("unknown")
            fingerprint_parts+=("oom:unknown")
        elif [ "$state" = "detected" ]; then
            problems+=("| _OOM kills_ | detected | - | - | ${approx} out-of-memory kill event(s) in the report lookback |")
            oom_problems+=("detected")
            fingerprint_parts+=("oom:detected")
        else
            healthy+=("OOM kills (none in the report lookback)")
        fi
        continue
    fi

    # Not a container either, and judged before the container rules for the same
    # reason `disk` and `backup` are. APPROX_SECONDS carries messages remaining
    # here — see health-report.sh, which does the conversion so that nothing
    # downstream has to know what a message costs.
    #
    # **There is no row at all when Twilio is not configured**, so this block
    # never fires on a Colony without an account.
    if [ "$name" = "sms" ]; then
        if [ "$state" = "unknown" ]; then
            problems+=("| _SMS balance_ | unknown | - | - | the vendor did not answer when asked for the balance |")
            sms_problems+=("unknown")
            fingerprint_parts+=("sms:unknown")
        elif [ "${approx:-0}" -le "$SMS_LOW_MESSAGES" ]; then
            problems+=("| _SMS balance_ | low | - | - | about ${approx} messages left at the dearest allowed destination |")
            sms_problems+=("low")
            # The count is out of the fingerprint for the reason the disk
            # percentage is: it moves on every send, and including it would file
            # a fresh comment on every run while the condition simply persists.
            fingerprint_parts+=("sms:low")
        else
            healthy+=("SMS balance (~${approx} messages)")
        fi
        continue
    fi

    # A timer is not a container either, and the question asked of it is not the
    # one asked of a service: not *is it running* — it is not, almost all of the
    # time, and that is correct — but *is it going to run again* (#66).
    case "$name" in
        timer|timer:*)
            unit="${name#timer:}"
            if [ "$state" = "none" ]; then
                problems+=("| _timers_ | none | - | - | the host installs no Colony timers at all |")
                timer_problems+=("none")
                fingerprint_parts+=("timer:none")
            elif [ "$state" = "not-scheduled" ]; then
                problems+=("| \`$unit\` | not scheduled | - | - | no next elapse — it has stopped scheduling, whatever it reports about being active |")
                timer_problems+=("$unit")
                fingerprint_parts+=("timer:$unit:not-scheduled")
            elif [ "$state" = "running" ]; then
                # Healthy, and the row says why it is not reporting a next
                # elapse (#138). A timer caught mid-run is the ordinary state of
                # a five-minute timer read by a watcher on its own schedule, and
                # reporting it as a fault is how a watcher gets muted.
                healthy+=("$unit (its service is running now, ${duration} in)")
            elif [ "$state" = "stuck" ]; then
                # Also no next elapse, and also not *stopped scheduling* — the
                # timer is waiting on a run that is not ending, which is a
                # different fault needing a different command. Naming it as
                # unscheduled would send the reader to `reenable`, which fixes
                # nothing here.
                problems+=("| \`$unit\` | service stuck | - | - | \`$image\` has been active for $duration, so the timer has no next elapse — the run is not ending |")
                timer_problems+=("$unit")
                fingerprint_parts+=("timer:$unit:stuck")
            else
                healthy+=("$unit (next in $duration)")
            fi
            continue
            ;;
        unit|unit:*)
            # A unit file is not a running thing at all, and the question asked
            # of it is neither *is it running* nor *will it run again* but
            # **does the host have the copy this repository thinks it has**
            # (#126). Nothing installs `systemd/`, so a merged unit fix can be
            # inert with no failure and no log line anywhere.
            file="${name#unit:}"
            if [ "$state" = "none" ]; then
                problems+=("| _units_ | none | - | - | the checkout carries no unit files to compare against |")
                unit_problems+=("none")
                fingerprint_parts+=("unit:none")
            elif [ "$state" = "drifted" ]; then
                problems+=("| \`$file\` | drifted | - | - | the host's copy differs from this repository's |")
                unit_problems+=("$file")
                fingerprint_parts+=("unit:$file:drifted")
            elif [ "$state" = "absent" ]; then
                # Its own row rather than folded into drift: a unit the host has
                # never had is fixed by installing it, and one that has fallen
                # behind is fixed by copying over it. Same remedy, different
                # sentence, and reading the wrong one wastes a look at the diff.
                problems+=("| \`$file\` | absent | - | - | this repository carries it and the host has no copy at all |")
                unit_problems+=("$file")
                fingerprint_parts+=("unit:$file:absent")
            else
                healthy+=("$file (matches the repository)")
            fi
            continue
            ;;
    esac

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

if [ "${#timer_problems[@]}" -gt 0 ]; then
    echo
    echo "A timer that has stopped scheduling reports itself healthy by every signal"
    echo "except one: \`is-active\` says active, \`is-enabled\` says enabled, the last"
    echo "run says success, and the \`timers.target.wants\` symlink is there (#65)."
    echo "Read the next elapse and nothing else, then look at the unit file rather"
    echo "than the service — this failure has been a unit-file defect once already:"
    echo
    echo '```'
    echo "systemctl list-timers --all"
    echo "systemctl show <timer> -p NextElapseUSecRealtime -p OnCalendar -p Unit"
    echo "sudo systemctl reenable <timer> && sudo systemctl restart <timer>"
    echo '```'
    echo
    echo "Nothing is necessarily broken yet: what these timers maintain — a backup, an"
    echo "allowlist — stays correct for a while after the refresh stops, which is why"
    echo "this is worth catching before the thing it refreshes goes stale."
    echo
    echo "**A \`service stuck\` row above is the other shape and needs the other command**"
    echo "(#138). There the timer is fine and is waiting on a run that is not ending, so"
    echo "\`reenable\` fixes nothing — the service is what to look at:"
    echo
    echo '```'
    echo "systemctl status <the service named in the row>"
    echo "journalctl -u <the service named in the row> -n 50"
    echo '```'
fi

if [ "${#unit_problems[@]}" -gt 0 ]; then
    echo
    echo "**A unit file that differs from this repository's is a change that was merged,"
    echo "reviewed, green — and inert.** Nothing deploys \`systemd/\`: \`deploy.sh\` resets"
    echo "/opt/kolonie from the checkout and \`/etc/systemd/system\` is not in it, so the"
    echo "repository says one thing and the host does another with no failure, no log"
    echo "line and no red tick anywhere (#126)."
    echo
    echo "Read the diff before copying. The drift may be the *host's* copy being right:"
    echo "a unit edited by hand during an incident is a fix somebody made under pressure"
    echo "and did not bring back, and overwriting it loses that."
    echo
    echo '```'
    echo "diff -u /etc/systemd/system/<unit> /opt/kolonie/systemd/<unit>"
    echo "sudo cp /opt/kolonie/systemd/<unit> /etc/systemd/system/<unit>"
    echo "sudo systemctl daemon-reload && sudo systemctl reenable <unit>"
    echo '```'
    echo
    echo "This is what #119 was: \`kolonie-image-prune.service\` gained \`StateDirectory\`"
    echo "here, the host's copy never got it, and Health Watch spent two days reporting"
    echo "that no prune had succeeded against a host that had freed 8 GiB on schedule."
fi

if [ "${#sms_problems[@]}" -gt 0 ]; then
    echo
    echo "When the Twilio balance reaches zero, sending stops and nothing looks wrong:"
    echo "a send the Colony cannot make is \`pending\` with the Colony named as the cause,"
    echo "so no citizen fails a rung and no other check notices. Auto-recharge is off on"
    echo "purpose — a finite balance is what stands between an OTP endpoint and the card"
    echo "— so topping up is a decision somebody makes, not something to automate away."
    echo
    echo "An \`unknown\` here is the vendor or the key, and not the balance. Check the key"
    echo "has not expired before adding money to an account that has plenty."
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

if [ "${#prune_problems[@]}" -gt 0 ]; then
    echo
    echo "The weekly image prune keeps five previous builds per application repository"
    echo "and protects every container and recorded rollback digest. Check the timer,"
    echo "the service result and the last run together:"
    echo
    echo '```'
    echo "systemctl list-timers kolonie-image-prune.timer"
    echo "systemctl status kolonie-image-prune.service"
    echo "journalctl -u kolonie-image-prune.service -n 50"
    echo '```'
fi

if [ "${#memory_problems[@]}" -gt 0 ] || [ "${#load_problems[@]}" -gt 0 ] ||
    [ "${#oom_problems[@]}" -gt 0 ]; then
    echo
    echo "Memory pressure, sustained processor saturation and an OOM kill are related"
    echo "signals, but not interchangeable. Read the current availability, the hour of"
    echo "sysstat history and the kernel event together:"
    echo
    echo '```'
    echo "free -h"
    echo "uptime"
    echo "sar -q"
    echo "journalctl -k --since '20 minutes ago'"
    echo '```'
fi

if [ "${#inode_problems[@]}" -gt 0 ]; then
    echo
    echo "A filesystem with free bytes can still refuse every write after its inodes"
    echo "are exhausted. Count files before deleting anything:"
    echo
    echo '```'
    echo "df -i /var/lib/docker"
    echo "sudo du --inodes -x --max-depth=2 /var/lib/docker | sort -n | tail"
    echo '```'
fi

# Sorted so the same set of problems in a different order is the same
# fingerprint. Without that, two unhealthy containers would look like a new
# situation whenever the daemon happened to list them the other way round.
echo "VERDICT=degraded" >&2
printf 'FINGERPRINT=%s\n' "$(printf '%s\n' "${fingerprint_parts[@]}" | sort | tr '\n' ',' | sed 's/,$//')" >&2

exit 1
