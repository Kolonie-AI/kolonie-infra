#!/bin/bash
# Publish one bit: is this host under resource pressure? `kolonie-infra#103`.
#
# Usage: ./scripts/pressure-report.sh [output-file]
#
# ## The line this is on the wrong side of
#
# `kolonie-infra#69` decided where alerting goes and gave the reason:
#
# > **Alerting goes somewhere a human reads without being at a computer.** Not a
# > GitHub issue — an issue is the right channel for the Watch Agent's
# > judgements, which can wait a day, and the wrong one for *"the host is gone"*,
# > which cannot.
#
# That line was drawn in the right place and **three things were on the wrong
# side of it**. *The disk is 90 % full* cannot wait a day: on a machine writing
# logs, database dumps and container layers, the distance between 90 % and a
# database that will not accept a write is hours — and the issue announcing it
# sits in a list nobody is looking at on a Sunday.
#
#   | Disk above the threshold | It fills further while nobody reads |
#   | Inodes exhausted         | Same, and it looks like a disk that is not full (#101) |
#   | Backups failing          | Silent until the day it is needed, which is the worst possible day |
#
# **Everything else keeps the issue**, which is the right channel for it: a
# container reporting unhealthy, deploy drift, and the Watch Agent's findings.
# `#103` is explicit that this must not become an alert per unhealthy container —
# that is the noise that makes people stop reading, and it is why the line was
# drawn at all.
#
# ## Why one bit, and why it is published rather than pushed
#
# **Inverted, because `#103` asks for no second alerting service.** UptimeRobot
# already watches five `/health` endpoints with `ALERT_NOT_EXISTS` on a keyword
# and mails a person when the keyword stops appearing. So this writes a file that
# contains that same keyword while the three conditions hold and something else
# when they do not, and a sixth monitor in `scripts/uptime-monitors.sh` watches
# it exactly like the other five. *The disk is full* becomes *the keyword is
# gone*, which is a shape that account already handles and already routes to a
# person. No new integration, no second place alerts can be missed, and no new
# credential.
#
# **The same `{"status":"ok"}` the five endpoints answer, and not a keyword of
# its own.** `uptime-monitors.sh` holds one keyword for the whole account; a
# second would be a per-monitor field that exists for one row. What this file
# means is carried by its path — `/status/pressure.json` — rather than by
# inventing a word for the account to match.
#
# **One bit and never a number.** The file is served publicly, so it says that
# there is pressure and never which resource or how much. A percentage on a
# public URL is a capacity map for anybody who wants to fill the disk faster than
# it drains, and it buys the reader nothing: the alert says *look now*, and the
# detail and the history are in the GitHub issue Health Watch already files.
# `#103` is explicit that the two are not alternatives.
#
# **A missing file is pressure.** nginx answers 404, the keyword is absent, and
# the monitor alerts. That is the correct direction and it is the whole reason
# for `ALERT_NOT_EXISTS`: this timer dying must not read as a healthy host.
#
# It follows that a dead website container also raises this alarm, attributing an
# nginx fault to the disk. That is accepted rather than solved: the console and
# website monitors distinguish the two within the same five minutes, and the cost
# of the alternative — a check that stays quiet when it cannot see — is the
# failure this file exists against.
#
# ## Thresholds
#
# **Read from the same variables `health-triage.sh` uses**, and defaulted to the
# same numbers, so the alarm and the issue cannot disagree about what *full*
# means. They are not restated here as literals for that reason.
set -uo pipefail

OUT="${1:-${PRESSURE_FILE:-/var/lib/kolonie/public/pressure.json}}"
REPORT="${PRESSURE_REPORT_CMD:-$(dirname "${BASH_SOURCE[0]}")/health-report.sh}"

DISK_FULL_PERCENT="${DISK_FULL_PERCENT:-85}"
INODE_FULL_PERCENT="${INODE_FULL_PERCENT:-85}"
BACKUP_STALE_SECONDS="${BACKUP_STALE_SECONDS:-129600}"

rows=$("$REPORT" 2>/dev/null)

# **An unreadable report is pressure, not health.** The same direction as the
# missing file: a probe that cannot see must not answer "fine".
if [ -z "${rows//[[:space:]]/}" ]; then
    verdict=degraded
else
    verdict=ok
    while IFS=$'\t' read -r name state _health _streak approx _rest; do
        case "$name" in
            disk)
                [ "$state" = ok ] || verdict=degraded
                [[ "$approx" =~ ^[0-9]+$ ]] || { verdict=degraded; continue; }
                [ "$approx" -ge "$DISK_FULL_PERCENT" ] && verdict=degraded
                ;;
            inodes)
                [ "$state" = ok ] || verdict=degraded
                [[ "$approx" =~ ^[0-9]+$ ]] || { verdict=degraded; continue; }
                [ "$approx" -ge "$INODE_FULL_PERCENT" ] && verdict=degraded
                ;;
            backup)
                [ "$state" = ok ] || verdict=degraded
                [[ "$approx" =~ ^[0-9]+$ ]] || { verdict=degraded; continue; }
                [ "$approx" -ge "$BACKUP_STALE_SECONDS" ] && verdict=degraded
                ;;
        esac
    done <<<"$rows"

    # A report that carried none of the three rows at all is not a healthy host
    # either — it is a report from somewhere this script cannot judge.
    printf '%s\n' "$rows" | cut -f1 | grep -qx disk || verdict=degraded
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null

# Replaced atomically and left world-readable: root writes it under systemd and
# nginx reads it as its own user through a bind mount. That is #119's mistake and
# it is not repeated — a marker only its writer can read is a marker nobody
# consults.
tmp=$(mktemp "$(dirname "$OUT")/.pressure.XXXXXX") || exit 1
printf '{"status":"%s"}\n' "$verdict" > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$OUT"

echo "pressure: $verdict -> $OUT"

# Always zero. A degraded host is what this reports, not a failure of the
# reporting — a non-zero exit would make systemd mark the unit failed and
# `health-report.sh` would then carry a second, confusing alarm about the timer.
exit 0
