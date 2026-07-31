#!/bin/bash
# Kolonie AI — why does a container call itself unhealthy?
#
# `scripts/health-report.sh` says *which* container is unhealthy and *for how
# long*. It does not say why, and neither does anything else that runs without a
# person: the reason lives in `.State.Health.Log`, which nothing reads.
#
# That is the same defect `#43` corrected one level down. There, a failed deploy
# reported `not healthy after 180s: api(unhealthy)` and threw away the container's
# own account of it, and the cost was twelve and a half hours. This is the same
# shape in the continuous path — the one that runs at three in the morning, where
# nobody is watching to go and look.
#
# **The health check is as likely to be wrong as the service is to be down.**
# `#11` is the case: kolonie-website was unhealthy for days while serving every
# request correctly, because the probe used `http://localhost:80/`, the image
# resolves localhost to `::1` as well as `127.0.0.1`, BusyBox wget tries `::1`
# first and nginx listened on IPv4 only. Reading the probe's own output is what
# separates that from a service that is genuinely down; the container state alone
# never can.
#
# Output is markdown, for a GitHub issue body, and **nothing at all when every
# container is healthy** — this is appended to a report that has to stay quiet.
#
# Usage:
#   ./scripts/health-why.sh                  every unhealthy container
#   ./scripts/health-why.sh name1 name2      those containers, whatever their state
#
# Needs a Docker daemon and nothing else. No secrets, no host names.

set -uo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"

# How much to quote. `.State.Health.Log` keeps only the last five entries however
# long the container has been failing — health-report.sh's header says why that
# matters — so five is the whole of what exists, not a choice.
#
# The container log is capped much harder than the deploy's 40 lines (#43). That
# one runs once, on a failure somebody triggered; this runs every fifteen minutes
# into an issue that stays open, so the same generosity would bury the report in
# its own evidence.
LOG_LINES="${HEALTH_WHY_LOG_LINES:-15}"
LOG_COLS="${HEALTH_WHY_LOG_COLS:-300}"

docker_cmd() {
    # `</dev/null` for the reason health-report.sh documents: without it the
    # docker CLI reads the stdin of the calling loop and swallows the rest of
    # the container list.
    if docker info >/dev/null 2>&1; then
        docker "$@" </dev/null
    else
        sudo -n docker "$@" </dev/null
    fi
}

unhealthy_containers() {
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@"
        return
    fi

    local names name
    if [ -d "$DEPLOY_DIR" ] && [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
        names=$(cd "$DEPLOY_DIR" && docker_cmd compose ps --all --format '{{.Name}}' 2>/dev/null)
    else
        names=$(docker_cmd ps --all --format '{{.Names}}')
    fi

    for name in $names; do
        [ -z "$name" ] && continue
        if [ "$(docker_cmd inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)" = "unhealthy" ]; then
            printf '%s\n' "$name"
        fi
    done
}

mapfile -t targets < <(unhealthy_containers "$@")
[ "${#targets[@]}" -eq 0 ] && exit 0

printf '\n## Why each of them says so\n'

for name in "${targets[@]}"; do
    [ -z "$name" ] && continue

    printf '\n### `%s`\n' "$name"

    # The probe's own output, per attempt, with its exit status. This is the
    # direct answer, and it is the one nothing has been reading.
    probe=$(docker_cmd inspect "$name" --format \
        '{{range .State.Health.Log}}exit={{.ExitCode}} {{.Output}}{{"\n"}}{{end}}' 2>/dev/null \
        | cut -c1-"$LOG_COLS" | grep -v '^[[:space:]]*$')

    if [ -n "$probe" ]; then
        printf '\nThe health check, last %s attempts Docker still holds:\n\n```\n%s\n```\n' \
            "$(printf '%s\n' "$probe" | wc -l)" "$probe"

        # Every line is an `exit=N` and nothing else. Worth saying, because a
        # block of bare exit codes looks like this script failed to collect the
        # output rather than like there was none to collect — and the two send a
        # reader to different places. A probe that says nothing is a probe that
        # cannot be debugged from here: the next step is running its command by
        # hand, not reading more of this.
        if ! printf '%s\n' "$probe" | sed 's/^exit=[0-9]* *//' | grep -q '[^[:space:]]'; then
            printf '\nEvery attempt exited without printing anything, so the status is all the\n'
            printf 'check ever said. Run its command inside the container to get further.\n'
        fi
    else
        printf '\nDocker holds no health-check attempts for this container at all.\n'
    fi

    # And what the service itself was saying. Bounded, and the risk stated where
    # it is taken: this republishes container output into a public issue that
    # stays open. A process that prints a secret at any point would have it
    # copied here, permanently. If a service ever needs to print something
    # sensitive, it must not print it to stdout or stderr.
    applog=$(docker_cmd logs --tail "$LOG_LINES" "$name" 2>&1 \
        | cut -c1-"$LOG_COLS" | grep -v '^[[:space:]]*$')

    if [ -n "$applog" ]; then
        printf '\nWhat the service printed, last %s lines:\n\n```\n%s\n```\n' "$LOG_LINES" "$applog"
    else
        printf '\nThe container printed nothing at all — the failure is before its first log line.\n'
    fi
done

printf '\nRead the probe output first. A health check is as likely to be wrong as the\n'
printf 'service is to be down: in `#11` the service was entirely fine and the check was\n'
printf 'looking at the wrong address family.\n'

exit 0
