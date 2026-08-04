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
# Plus one row that is not a container, on a host that has a deploy directory:
#
#   backup  ok|never  -  0  <seconds since the last successful backup>  -
#
# And one row per systemd timer the Colony installs, on the same hosts:
#
#   timer:<unit>  ok|not-scheduled  -  0  <seconds until the next elapse>  -
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
    # APPROX_SECONDS carries the percentage used, because the row format has no
    # other numeric column and adding one would change what health-triage.sh
    # parses. Ugly, and confined to these two files.
    disk_pct=$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
    [ -z "$disk_pct" ] && disk_pct=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$disk_pct" ]; then
        printf 'disk\tok\t-\t0\t%s\t-\n' "$disk_pct"
    else
        # Say nothing rather than report 0%. An unreadable df reported as an
        # empty disk is the direction that hides the problem.
        printf 'disk\tunknown\t-\t0\t0\t-\n'
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
fi

exit 0
