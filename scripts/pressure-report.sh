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
# ## A degraded reading is not a degraded host
#
# The paragraph above is about what to do when the number is missing, and it is
# right. `#157` is about the case it was over-applied to: a number that is
# *there* and a row that merely says the reader did not get everything it asked
# for.
#
# `health-report.sh` builds the disk row from two sources — `df` for the
# percentage, `docker system df` for the reclaimable image bytes — and writes
# three different states for the three different things that can happen:
#
#   | `ok`      | both answered |
#   | `partial` | `df` answered, `docker system df` did not |
#   | `unknown` | `df` itself did not answer, and the percentage column is `0` |
#
# Only `df` is a pressure fact. `docker system df` is *how much of the disk
# could be reclaimed by deleting images*, which is what the Health Watch issue
# is for and is not what wakes anybody up. Reading `partial` as pressure meant
# the alarm fired on the second source going quiet while the first sat there
# saying 40 %.
#
# **And it goes quiet for one predictable reason: a deploy.** Both of the two
# `degraded` verdicts this timer has ever produced — 622 runs over 14 days —
# fell inside a `docker compose pull`, where `docker system df` competes with a
# pull writing layers and the whole run finishes in 9–13 seconds against a usual
# 85–120. Neither host was under pressure; disk was 40 %, inodes 26 %. A monitor
# whose only two alarms were both deploys is a monitor people stop reading, and
# `#103` drew the line where it did precisely to stop that happening.
#
# **`unknown` is untouched and stays pressure**, which is the whole reason the
# distinction is drawn here rather than *any state with a number in it is fine*.
# When `df` does not answer there is no number: the column holds a `0` that
# means *nothing was measured*, and a check that read it as an empty disk would
# be the quiet failure this file exists against.
#
# **The timer is not made deploy-aware, deliberately.** Skipping a run while the
# compose lock is held would suppress the symptom and cost the one property that
# makes this alarm trustworthy — it runs unconditionally, so it cannot be
# reasoned into silence. The two 13-second runs are worth naming as a signal,
# but that signal belongs in the Health Watch issue where a short run can be
# looked at, not in a bit that pages a person at midnight.
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

# **Only the three rows this file judges** (`#223`).
#
# It used to run the whole report — twelve `docker inspect` calls, the unit
# comparison, journal scans and an HTTPS call to Twilio for the SMS balance — to
# read a disk percentage, an inode percentage and the age of a file. Measured on
# the deploy host on 2026-08-19: 49.9 s to 58.2 s per pass, on a five-minute
# timer. `#221` caught the timer with no next elapse when one pass ran past the
# interval.
#
# The rows are named here rather than defaulted in `health-report.sh`, because
# the three this file reads and the three it thresholds below have to be the same
# three, and a default in the other file could drift from this one silently.
rows=$("$REPORT" --rows disk,inodes,backup 2>/dev/null)

# **An unreadable report is pressure, not health.** The same direction as the
# missing file: a probe that cannot see must not answer "fine".
if [ -z "${rows//[[:space:]]/}" ]; then
    verdict=degraded
else
    verdict=ok
    while IFS=$'\t' read -r name state _health _streak approx _rest; do
        case "$name" in
            disk)
                # `partial` is judged on the percentage; every other non-`ok`
                # state is pressure. See *A degraded reading is not a degraded
                # host* above — and note that `unknown` may not fall through to
                # the numeric test, because `health-report.sh` writes `0` in the
                # percentage column when `df` did not answer, and 0 is below
                # every threshold there will ever be.
                case "$state" in
                    ok | partial) ;;
                    *) verdict=degraded; continue ;;
                esac
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
