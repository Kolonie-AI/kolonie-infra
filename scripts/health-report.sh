#!/bin/bash
# Kolonie AI — container health report (#11)
#
# Answers the question nothing was asking: **what does each container think of
# itself, and for how long has it thought that?**
#
# scripts/healthcheck.sh answers a different one — "is the stack healthy right
# now" — and is used as a deploy gate, where a non-zero exit is the point. This
# one never gates anything. It prints a row per container and exits 0 whatever it
# finds, because its caller is a watcher that has to distinguish "one container
# is unhealthy" from "the report itself failed to run".
#
# **Why the container's own opinion and not an HTTP probe.** On 2026-07-28
# kolonie-website was unhealthy for an unknown number of days while serving every
# request correctly: the check used http://localhost:80/, the image maps
# localhost to ::1 as well as 127.0.0.1, BusyBox wget tries ::1 first, and nginx
# listens on IPv4 only. Traefik answered 200 the whole time, so every external
# check passed. The only wrong thing in the world was the container's own health
# status — and the only reader of it was the deploy script, which found it days
# later and rolled the site back for half an hour.
#
# An external probe would not have caught that, and would not catch it now. That
# asymmetry is the whole reason this script reads `docker inspect`.
#
# Output, one tab-separated row per container:
#
#   NAME  STATE  HEALTH  FAILING_STREAK  APPROX_SECONDS  IMAGE
#
# Plus rows that are not containers, on a host that has a deploy directory:
#
#   backup  ok|never  -  0  <seconds since the last successful backup>  -
#   disk  ok|partial|unknown  -  <reclaimable image bytes>  <percentage used>  <image bytes>
#   image-prune  ok|never|missing|failed  -  <bytes freed>  <seconds since success>  -
#   memory  ok|unknown  -  <available KiB>  <percentage available>  <total KiB>
#   inodes  ok|unknown  -  0  <percentage used>  <mount>
#   load  ok|unknown  <cores>  <window seconds>  <percentage of cores>  <load>
#   oom  clear|detected|unknown  -  0  <events in the lookback>  -
#
# And one row per systemd timer the Colony installs, on the same hosts:
#
#   timer:<unit>  ok|not-scheduled  -  0  <seconds until the next elapse>  -
#
# And one row per unit file this repository carries, on a host that has a
# checkout of it (#126):
#
#   unit:<name>  ok|drifted|absent  -  0  0  -
#
# **The field is the next elapse, and deliberately not whether the unit is
# active** (#66). `kolonie-origin-firewall.timer` had not scheduled anything for
# three days while reporting `is-active: active`, `is-enabled: enabled`,
# `Result=success` and a present `timers.target.wants` symlink (#65). Every
# signal anyone would think to check said it was healthy; the only one that did
# not was `NextElapseUSecRealtime`, empty, which nobody reads. It was found by
# hand while verifying something else, and the rules it maintains had simply
# stopped being refreshed in the meantime.
#
# A backup that quietly stops is the failure this catches, and it is the one
# failure mode a backup system reliably has. Nothing else on the host notices:
# the timer keeps firing, the unit keeps failing into the journal, every
# container stays green, and the gap is discovered by the person restoring. The
# report states the age; health-triage.sh decides when that age is a problem
# (#4).
#
# HEALTH is one of healthy / unhealthy / starting / none. APPROX_SECONDS is how
# long it has been failing, and it is approximate on purpose: Docker records no
# "unhealthy since" timestamp, so this is the failing streak multiplied by the
# check interval. Good enough to tell minutes from days, which is the distinction
# that matters, and it does not depend on .State.Health.Log — that keeps only the
# last five entries, so a container unhealthy for a week looks identical to one
# unhealthy for two minutes if you read the log.
#
# Usage:
#   ./scripts/health-report.sh                  every container in the compose project
#   ./scripts/health-report.sh name1 name2      those containers by name
#
# Needs a Docker daemon it can talk to and nothing else. No secrets, no host
# names: it prints what the local daemon reports about local containers.

set -uo pipefail

# The deploy directory when it exists, otherwise wherever it was called from —
# so this runs against a checkout on a workstation as readily as on the host.
DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"

docker_cmd() {
    # The host's ubuntu user is in the docker group; a workstation user may not
    # be. Trying the plain command first keeps the common path free of sudo.
    #
    # `</dev/null` is not decoration. Without it the docker CLI reads the stdin
    # of whatever loop calls it and swallows the rest of the container list — the
    # report then covers exactly one container and looks like a healthy stack.
    # Found by running this against four containers and getting one row.
    if docker info >/dev/null 2>&1; then
        docker "$@" </dev/null
    else
        sudo -n docker "$@" </dev/null
    fi
}

size_bytes() {
    # Docker's system-df format is human-readable SI. Keep the conversion here
    # so the report remains numeric and triage does not have to parse daemon UI.
    local value="$1" number multiplier
    case "$value" in
        *kB) number=${value%kB}; multiplier=1000 ;;
        *MB) number=${value%MB}; multiplier=1000000 ;;
        *GB) number=${value%GB}; multiplier=1000000000 ;;
        *TB) number=${value%TB}; multiplier=1000000000000 ;;
        *PB) number=${value%PB}; multiplier=1000000000000000 ;;
        *EB) number=${value%EB}; multiplier=1000000000000000000 ;;
        *B) number=${value%B}; multiplier=1 ;;
        *) return 1 ;;
    esac
    [[ "$number" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v number="$number" -v multiplier="$multiplier" \
        'BEGIN { printf "%.0f", number * multiplier }'
}

containers() {
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@"
        return
    fi

    if [ -d "$DEPLOY_DIR" ] && [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
        (cd "$DEPLOY_DIR" && docker_cmd compose ps --all --format '{{.Name}}' 2>/dev/null)
    else
        docker_cmd ps --all --format '{{.Names}}'
    fi
}

# One inspect per container rather than one for all of them: a name that no
# longer exists must not take the whole report down with it. A watcher that
# prints nothing because one container was renamed is a watcher that has stopped
# watching without saying so.
inspect_row() {
    local name="$1"

    # `.Interval.Nanoseconds` rather than `.Interval`. A Go template renders a
    # time.Duration through its String method — "5s", "1m0s" — and feeding that
    # to shell arithmetic is an error, not a zero: the row is lost and the
    # container silently drops out of the report. Calling the method gives an
    # integer, which is what the arithmetic below actually wants.
    docker_cmd inspect "$name" --format '
{{- $h := .State.Health -}}
{{- .Name}}	{{.State.Status}}	{{if $h}}{{$h.Status}}{{else}}none{{end}}	{{if $h}}{{$h.FailingStreak}}{{else}}0{{end}}	{{if .Config.Healthcheck}}{{.Config.Healthcheck.Interval.Nanoseconds}}{{else}}0{{end}}	{{.Config.Image}}' 2>/dev/null
}

# Collected before the loop rather than piped into it. Two reasons, and the
# second one bit: a list read up front cannot be truncated by a command inside
# the loop, and `emitted` stays in this shell rather than a subshell's.
mapfile -t names < <(containers "$@")

emitted=0

for name in "${names[@]}"; do
    [ -z "$name" ] && continue

    row="$(inspect_row "$name")"
    if [ -z "$row" ]; then
        # Named in the compose project but not present. A watcher must report
        # this rather than skip it — a container that vanished is further from
        # healthy than one that is merely unhealthy.
        printf '%s\tgone\tnone\t0\t0\t-\n' "$name"
        emitted=$((emitted + 1))
        continue
    fi

    # Docker prints the container name with a leading slash.
    IFS=$'\t' read -r cname state health streak interval image <<<"$(printf '%s' "$row" | tr -d '\n')"
    cname="${cname#/}"

    interval_s=$(((${interval:-0}) / 1000000000))
    [ "$interval_s" -le 0 ] && interval_s=30
    approx=$(((${streak:-0}) * interval_s))

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cname" "$state" "$health" "$streak" "$approx" "$image"
    emitted=$((emitted + 1))
done

if [ "$emitted" -eq 0 ]; then
    # Distinguishable from a healthy stack on purpose. "No containers" and "all
    # containers fine" are opposite situations that a row count alone confuses,
    # and the watcher has to be able to tell an empty host from a quiet one.
    echo "NO_CONTAINERS	-	-	0	0	-"
fi

# Emitted after the container rows and deliberately outside the `emitted`
# accounting above: a host with no containers must still report NO_CONTAINERS,
# and counting this row would have suppressed that. "No containers" and "the
# backup is late" are independent facts and both have to survive to the triage.
#
# Only where a deploy directory exists. On a workstation checkout there is no
# backup to be late, and a row claiming one would make every local run of this
# report look degraded — which is how a watcher gets ignored. Skipped when
# specific containers were named, because then the caller asked a narrower
# question than "how is this host".
if [ -d "$DEPLOY_DIR" ] && [ "$#" -eq 0 ]; then
    # Same default as backup.sh, and deliberately not $DEPLOY_DIR/backups —
    # that one holds deploy.sh's container-state snapshots. See the comment on
    # WORK_DIR in backup.sh.
    marker="${KOLONIE_BACKUP_DIR:-/var/backups/kolonie}/.last-success"
    last_epoch=""
    if [ -r "$marker" ]; then
        # `date -d` parses the ISO-8601 that backup.sh writes. If it ever cannot,
        # the row says `never` rather than reporting an age of zero — a
        # malformed timestamp must not read as "backed up just now", which is
        # the direction that hides the problem.
        last_epoch=$(date -d "$(cat "$marker" 2>/dev/null)" +%s 2>/dev/null || echo "")
    fi

    if [ -n "$last_epoch" ]; then
        printf 'backup\tok\t-\t0\t%s\t-\n' "$(( $(date +%s) - last_epoch ))"
    else
        printf 'backup\tnever\t-\t0\t0\t-\n'
    fi

    # A third row that is not a container: how full the partition the containers
    # write to is (#37).
    #
    # Capping the logs in docker-compose.yml bounds the one thing that was
    # unbounded, and it is not a disk monitor — images, volumes, backups and the
    # Postgres data directory all still grow, and a full partition takes every
    # service down at once for a reason none of their logs can record, because
    # there is nowhere left to record it. The cap makes that slower; only a
    # threshold makes it visible.
    #
    # APPROX_SECONDS carries the percentage used. FAILING_STREAK and IMAGE carry
    # reclaimable and total image bytes: the six-column stream stays stable while
    # the reader sees capacity and removable image growth as one disk fact.
    disk_pct=$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
    [ -z "$disk_pct" ] && disk_pct=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$disk_pct" ]; then
        image_df=$(docker_cmd system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null |
            awk -F'\t' '$1 == "Images" { print; exit }')
        IFS=$'\t' read -r _image_type image_size image_reclaimable <<<"$image_df"
        image_size_bytes=$(size_bytes "${image_size:-}" 2>/dev/null || echo "")
        image_reclaimable_bytes=$(size_bytes "${image_reclaimable%% *}" 2>/dev/null || echo "")
        if [ -n "$image_size_bytes" ] && [ -n "$image_reclaimable_bytes" ]; then
            printf 'disk\tok\t-\t%s\t%s\t%s\n' \
                "$image_reclaimable_bytes" "$disk_pct" "$image_size_bytes"
        else
            printf 'disk\tpartial\t-\t0\t%s\t-\n' "$disk_pct"
        fi
    else
        # Say nothing rather than report 0%. An unreadable df reported as an
        # empty disk is the direction that hides the problem.
        printf 'disk\tunknown\t-\t0\t0\t-\n'
    fi

    # The timer's next elapse says whether it will be invoked again; its service
    # result and success marker say whether invocation actually works. All three
    # are needed: a timer can remain scheduled while its service fails forever.
    prune_unit=kolonie-image-prune.timer
    prune_service=kolonie-image-prune.service
    prune_marker="${KOLONIE_STATE_DIR:-/var/lib/kolonie}/image-prune.env"
    prune_load=$(systemctl show "$prune_unit" -p LoadState --value 2>/dev/null || echo "")
    prune_result=$(systemctl show "$prune_service" -p Result --value 2>/dev/null || echo "")
    prune_epoch=""
    prune_freed=0
    if [ -r "$prune_marker" ]; then
        prune_epoch=$(sed -n 's/^LAST_SUCCESS_EPOCH=//p' "$prune_marker" | tail -1)
        prune_freed=$(sed -n 's/^LAST_FREED_BYTES=//p' "$prune_marker" | tail -1)
    fi
    case "$prune_freed" in ''|*[!0-9]*) prune_freed=0 ;; esac
    if [ "$prune_load" != loaded ]; then
        printf 'image-prune\tmissing\t-\t0\t0\t-\n'
    elif [ -n "$prune_result" ] && [ "$prune_result" != success ]; then
        printf 'image-prune\tfailed\t-\t%s\t0\t-\n' "$prune_freed"
    elif [[ "$prune_epoch" =~ ^[0-9]+$ ]]; then
        printf 'image-prune\tok\t-\t%s\t%s\t-\n' \
            "$prune_freed" "$(( $(date +%s) - prune_epoch ))"
    else
        printf 'image-prune\tnever\t-\t0\t0\t-\n'
    fi

    # Memory available, not memory used (#101). Linux deliberately fills spare
    # memory with reclaimable cache, so `used` rises on a healthy host and is the
    # wrong number to put in front of a threshold. MemAvailable already accounts
    # for what the kernel can give an application without swapping.
    meminfo="${MEMINFO_PATH:-/proc/meminfo}"
    mem_total=$(awk '$1 == "MemTotal:" { print $2; exit }' "$meminfo" 2>/dev/null)
    mem_available=$(awk '$1 == "MemAvailable:" { print $2; exit }' "$meminfo" 2>/dev/null)
    if [ "${mem_total:-0}" -gt 0 ] 2>/dev/null && [ -n "$mem_available" ]; then
        mem_available_pct=$((mem_available * 100 / mem_total))
        printf 'memory\tok\t-\t%s\t%s\t%s\n' \
            "$mem_available" "$mem_available_pct" "$mem_total"
    else
        printf 'memory\tunknown\t-\t0\t0\t-\n'
    fi

    # Inodes are a second, independent way for a writable partition to become
    # full (#101). Use the Docker partition when it exists and the root
    # partition otherwise, exactly as the byte check above does.
    inode_mount=/var/lib/docker
    inode_pct=$(df -Pi "$inode_mount" 2>/dev/null |
        awk 'NR > 1 { value=$5 } END { gsub(/%/, "", value); print value }')
    if [ -z "$inode_pct" ]; then
        inode_mount=/
        inode_pct=$(df -Pi "$inode_mount" 2>/dev/null |
            awk 'NR > 1 { value=$5 } END { gsub(/%/, "", value); print value }')
    fi
    if [ -n "$inode_pct" ]; then
        printf 'inodes\tok\t-\t0\t%s\t%s\n' "$inode_pct" "$inode_mount"
    else
        printf 'inodes\tunknown\t-\t0\t0\t-\n'
    fi

    # sysstat already samples the host every ten minutes. Read its last hour
    # rather than adding a collector or treating one instantaneous spike as an
    # incident (#101). `sar -q`'s Average row is the mean of the recorded
    # 15-minute load averages in that window; normalising it by the online core
    # count makes the result comparable if the host size changes.
    load_window_seconds="${LOAD_WINDOW_SECONDS:-3600}"
    load_start=$(date -d "$load_window_seconds seconds ago" +%H:%M:%S 2>/dev/null || echo "")
    load_start_day=$(date -d "$load_window_seconds seconds ago" +%d 2>/dev/null || echo "")
    today=$(date +%d)
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")
    load_average=""
    if [ -n "$load_start" ] && [ "${cores:-0}" -gt 0 ] 2>/dev/null && command -v sar >/dev/null 2>&1; then
        # `sar -s` reads today's archive. During the first hour after midnight
        # the window starts in yesterday's, so read both rather than reporting
        # a daily blind spot. Average the actual ten-minute samples, not each
        # file's Average row, so a short side of the boundary is not overweighted.
        if [ "$load_start_day" != "$today" ] && [ -r "/var/log/sysstat/sa${load_start_day}" ]; then
            load_samples=$(
                LC_ALL=C S_TIME_FORMAT=ISO sar -q -f "/var/log/sysstat/sa${load_start_day}" \
                    -s "$load_start" 2>/dev/null
                LC_ALL=C S_TIME_FORMAT=ISO sar -q 2>/dev/null
            )
        else
            load_samples=$(LC_ALL=C S_TIME_FORMAT=ISO sar -q -s "$load_start" 2>/dev/null)
        fi
        load_average=$(printf '%s\n' "$load_samples" | awk \
            '$1 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/ && $6 ~ /^[0-9]+([.][0-9]+)?$/ {
                total += $6; samples++
            }
            END { if (samples > 0) printf "%.2f", total / samples }')
    fi
    if [ -n "$load_average" ]; then
        load_pct=$(awk -v avg="$load_average" -v ncores="$cores" \
            'BEGIN { printf "%d", (avg * 100 / ncores) + 0.5 }')
        printf 'load\tok\t%s\t%s\t%s\t%s\n' \
            "$cores" "$load_window_seconds" "$load_pct" "$load_average"
    else
        printf 'load\tunknown\t%s\t%s\t0\t-\n' "${cores:-0}" "$load_window_seconds"
    fi

    # An OOM kill is an event, not a low-memory state: by the next sample the
    # killed process is gone and MemAvailable may look healthy again (#101).
    # Twenty minutes overlaps the fifteen-minute watcher cadence so a delayed
    # scheduled run does not leave a gap. A repeated observation has the same
    # fingerprint downstream, so the overlap does not repeat notifications.
    oom_lookback_minutes="${OOM_LOOKBACK_MINUTES:-20}"
    oom_log=$(sudo -n journalctl -k --since "$oom_lookback_minutes minutes ago" \
        --no-pager -q 2>/dev/null)
    oom_status=$?
    if [ "$oom_status" -ne 0 ]; then
        printf 'oom\tunknown\t-\t0\t0\t-\n'
    else
        oom_events=$(printf '%s\n' "$oom_log" |
            grep -Eic 'oom-kill:|Out of memory: Killed process|Killed process [0-9]+')
        if [ "$oom_events" -gt 0 ]; then
            printf 'oom\tdetected\t-\t0\t%s\t-\n' "$oom_events"
        else
            printf 'oom\tclear\t-\t0\t0\t-\n'
        fi
    fi

    # The Twilio balance, when there is a Twilio account (#83).
    #
    # **Running out fails silently, and that is the whole reason this exists.**
    # Auto-recharge is deliberately off — an OTP endpoint that sends to a number
    # the caller chose is the standard target for SMS pumping, and a finite
    # balance is the only thing between that and the card. The cost of that
    # choice is that when the balance reaches zero, sending stops, every citizen
    # on a phone rung stalls, and **nothing looks wrong**: the verifier's own
    # contract makes a send the Colony cannot make `pending` with the Colony
    # named as the cause, so no citizen fails and no alarm fires.
    #
    # **APPROX_SECONDS carries messages remaining, not dollars and not seconds.**
    # A dollar figure silently means something different every time the
    # allowlist changes — $40 is four hundred messages to the US and three
    # hundred and fifty to Germany — so the number that reaches the triage is
    # already denominated in the thing that runs out. Same borrowed column the
    # `disk` row above uses, and confined to these two files for the same reason.
    #
    # **Absent configuration means no row at all.** A Colony with no Twilio
    # account is not unhealthy, and a row saying `unknown` on every workstation
    # run is how a watcher gets ignored.
    #
    # **The values come out of `.env`, because nothing else puts them in this
    # shell.** `health-watch.yml` runs this over SSH as `cd $DEPLOY_DIR &&
    # ./scripts/health-report.sh`; the `TWILIO_*` variables live in
    # `$DEPLOY_DIR/.env`, which Compose reads and a login shell does not. A
    # version of this check that only read the environment would have been
    # correct in the rehearsal and silent in production, for ever — which is the
    # exact shape of failure `#84` and `#85` are both about.
    #
    # Read key by key rather than sourced. `.env` is a file `set -a; . ./.env`
    # would execute, and this script runs on the host that holds the database
    # password.
    if [ -r "$DEPLOY_DIR/.env" ]; then
        for var in TWILIO_ACCOUNT_SID TWILIO_API_KEY_SID TWILIO_API_KEY_SECRET \
            SMS_DEAREST_DESTINATION_CENTS; do
            # Only when the environment did not already carry it, so the
            # rehearsal and a manual run can override without editing anything.
            [ -n "${!var:-}" ] && continue
            value=$(sed -n "s/^${var}=//p" "$DEPLOY_DIR/.env" | tail -1 | tr -d '"'"'"'\r')
            [ -n "$value" ] && printf -v "$var" '%s' "$value"
        done
    fi

    if [ -n "${TWILIO_ACCOUNT_SID:-}" ] && [ -n "${TWILIO_API_KEY_SID:-}" ] &&
        [ -n "${TWILIO_API_KEY_SECRET:-}" ]; then
        # The base is a variable so the rehearsal can point it at a stub. It is
        # not configuration anybody sets on the host, and it is not in
        # `.env.example` for that reason.
        twilio_base="${TWILIO_API_BASE:-https://api.twilio.com}"

        # `--fail` so a 401 is a failure rather than an error document parsed as
        # a balance. `-u` puts the key in the request and not in the output;
        # nothing below ever prints the response.
        balance_json=$(curl -sS --fail --max-time 10 \
            -u "${TWILIO_API_KEY_SID}:${TWILIO_API_KEY_SECRET}" \
            "${twilio_base}/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Balance.json" 2>/dev/null || echo "")

        # The most expensive destination the allowlist admits, in cents, so the
        # arithmetic below is integer. Measured against this account on
        # 2026-08-05: DE $0.112 · AT $0.0979 · CH $0.0769 · GB $0.056 · US
        # $0.0083. Configurable because the allowlist is, and defaulted to
        # Germany because Germany is the most expensive of the five.
        dearest_cents="${SMS_DEAREST_DESTINATION_CENTS:-12}"

        balance=$(printf '%s' "$balance_json" |
            sed -n 's/.*"balance"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9.-]*\).*/\1/p')

        if [ -z "$balance" ]; then
            # **`unknown`, never `low`.** A network blip, a 500 at the vendor or
            # an expired key all land here, and an alarm that fires on any of
            # them is an alarm somebody turns off — after which the real one is
            # not heard either.
            printf 'sms\tunknown\t-\t0\t0\t-\n'
        else
            # Truncating integer division, in cents, so a balance of $0.11 with
            # a $0.112 message reports zero remaining rather than one.
            balance_cents=$(printf '%s' "$balance" | awk '{printf "%d", $1 * 100}')
            remaining=$((balance_cents / dearest_cents))
            [ "$remaining" -lt 0 ] && remaining=0
            printf 'sms\tok\t-\t0\t%s\t-\n' "$remaining"
        fi
    fi

    # One row per timer (#66). Both of the Colony's timers maintain something
    # whose absence is invisible for a while and expensive later — a backup
    # nobody took, an allowlist nobody refreshed — which is the same instinct as
    # the backup row above, one level down: that row checks the artefact, this
    # one checks the thing that produces it.
    #
    # **Enumerated, not named.** Listing `kolonie-backup.timer` and
    # `kolonie-origin-firewall.timer` here would cover a third timer on the day
    # somebody remembered this comment rather than the day it landed.
    #
    # **The pattern is the Colony's own prefix and not every timer on the host.**
    # A stock Ubuntu carries `apt-daily`, `fstrim`, `man-db` and more; several
    # are legitimately unscheduled, none of them is this repository's to
    # maintain, and reporting them would drown the two rows that matter. The
    # prefix is the naming convention the units in this repository already
    # follow, so a third one is covered by existing.
    if command -v systemctl >/dev/null 2>&1; then
        timers=0
        while read -r unit _rest; do
            [ -z "$unit" ] && continue
            timers=$((timers + 1))

            # The one field that told the truth during #65. Empty is the
            # failure; `systemctl is-active` was `active` throughout and is
            # exactly what makes the obvious version of this check useless.
            next="$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null)"
            if [ -z "$next" ]; then
                printf 'timer:%s\tnot-scheduled\t-\t0\t0\t-\n' "$unit"
                continue
            fi

            # An unparseable value is reported as scheduled with an unknown
            # distance rather than as broken: what was asked is whether a next
            # elapse exists, and it does. The alternative direction would file a
            # fault against a working timer because `date` did not like a
            # locale, which is how a watcher gets muted.
            next_epoch="$(date -d "$next" +%s 2>/dev/null || echo "")"
            if [ -n "$next_epoch" ]; then
                until_next=$((next_epoch - $(date +%s)))
                [ "$until_next" -lt 0 ] && until_next=0
            else
                until_next=0
            fi
            printf 'timer:%s\tok\t-\t0\t%s\t-\n' "$unit" "$until_next"
        done < <(systemctl list-unit-files --type=timer --no-legend \
                     "${KOLONIE_TIMER_PATTERN:-kolonie-*.timer}" 2>/dev/null)

        # Same reasoning as NO_CONTAINERS. A host that has lost its timer units
        # altogether reports nothing at all here, and silence is what this whole
        # row exists to stop being an answer.
        [ "$timers" -eq 0 ] && printf 'timer\tnone\t-\t0\t0\t-\n'
    fi

    # One row per unit whose file on the host differs from this repository's
    # (#126). **Nothing installs `systemd/`**: `deploy.sh` resets /opt/kolonie
    # from the checkout and `/etc/systemd/system` is not in it, so a unit change
    # merged here is green, reviewed and inert — no failure, no log line, no red
    # tick, and the only way to learn which is to go and look.
    #
    # **Measured, not feared.** Audited on 2026-08-11: one of the ten had
    # drifted. `kolonie-image-prune.service` had gained `StateDirectory=kolonie`
    # here and the host's copy never got it, so /var/lib/kolonie did not exist,
    # the weekly prune had nowhere to write its marker, and the `image-prune` row
    # above reported *no successful prune has been recorded* against a host that
    # had freed 8 GiB on schedule. That is #119: an alarm open for two days
    # describing the opposite of what happened. Nine units were fine and nothing
    # said which nine.
    #
    # **This is a detector and not an installer**, deliberately. Making a deploy
    # write /etc/systemd/system and reload systemd hands the deploy path root
    # over unit files, including the unit that runs the deploy — a larger
    # decision that may well be right and is not this one. A drift nobody can see
    # cannot be argued about; a drift on a report is fixed by hand in one
    # command, which is what happened here.
    #
    # **Both sides are already on this machine, in this process, for free.**
    # health-report.sh runs from $DEPLOY_DIR, which *is* the checkout — the same
    # arrangement code-drift.sh and env-drift.sh use for this shape of question.
    #
    #   unit:<name>  ok|drifted|absent  -  0  0  -
    #
    # `absent` is its own state and not a drift: a unit this repository carries
    # and the host has never had is a different thing from one whose copy has
    # fallen behind, and it is the state every unit is in on a host built before
    # the file existed. Both are degraded; only one is fixed by copying.
    if [ -d "$DEPLOY_DIR/systemd" ]; then
        units=0
        for source in "$DEPLOY_DIR"/systemd/*.service "$DEPLOY_DIR"/systemd/*.timer; do
            [ -f "$source" ] || continue
            units=$((units + 1))
            name=$(basename "$source")
            installed="${KOLONIE_UNIT_DIR:-/etc/systemd/system}/$name"

            if [ ! -f "$installed" ]; then
                printf 'unit:%s\tabsent\t-\t0\t0\t-\n' "$name"
            elif cmp -s "$source" "$installed"; then
                printf 'unit:%s\tok\t-\t0\t0\t-\n' "$name"
            else
                printf 'unit:%s\tdrifted\t-\t0\t0\t-\n' "$name"
            fi
        done

        # The same rule as the timer rows above and for the same reason: a
        # checkout carrying no units at all must not read as every unit being
        # fine.
        [ "$units" -eq 0 ] && printf 'unit\tnone\t-\t0\t0\t-\n'
    fi
fi

exit 0
