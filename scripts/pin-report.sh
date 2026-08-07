#!/bin/bash
# Kolonie AI — is the host running the images its own record names? (#89)
#
# On 2026-08-06 production ran an `api` image two days and 212 commits behind
# what `state/deployed.env` said was deployed, and nothing anywhere reported it.
# Every other service was digest-pinned and had been recreated by the deploy that
# wrote that record; only `api` was on a floating tag, created an hour after the
# deploy it was supposedly part of.
#
# **`deployed.env` is a record of intent, and drift makes it fiction.** It is
# written after a successful health check and was never re-read against the host
# afterwards. Once the two disagree, the file everything reads — `rollback.sh`
# most of all — is the one that is wrong.
#
# This is the re-reading. It answers, per service: what does the record name,
# and what is the container actually running.
#
# ## Why this is not `deployed-revision.sh | drift-triage.sh`
#
# That pair asks a different question and #44 settled its reference deliberately:
# **the newest image built and pushed** for each service. That is the right
# reference for *is a build waiting that this host has not taken*, and it is the
# wrong one here, for the reason #89's own comment names — when the failure is in
# the **build**, no newer image is ever pushed, so the host matches the newest
# one that exists and the check answers `current` while serving week-old code.
# The reference moved backwards with the host and the comparison stayed true.
#
# This check compares against the **record**, which moves only when a deploy
# succeeds. The two are independent and both are worth having: one notices a
# build nobody took, the other notices a container nobody meant to start.
#
# Output, one tab-separated row per service:
#
#   SERVICE  RECORDED_REF  RECORDED_ID  RUNNING_ID
#
# `-` in any field means *not known*, and the caller has to tell that apart from
# a value it simply does not recognise. This script never guesses: it reports
# what it read. The judgement is `pin-triage.sh`, which is separate so that it
# can be tested without a deploy host — the same split health-report.sh and
# health-triage.sh already use.
#
# Usage:
#   ./scripts/pin-report.sh | ./scripts/pin-triage.sh
#
# Needs a Docker daemon and `state/deployed.env`. No secrets, no host names, no
# registry access, and it never starts, stops or pulls anything.

set -uo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
STATE_FILE="${DEPLOY_DIR}/state/deployed.env"

# Service name, then the variable in `deployed.env` that pins it. Stated rather
# than derived: the two vocabularies genuinely differ — `verifier-runner` is
# `RUNNER_IMAGE` and `support-triage-runner` is `TRIAGE_IMAGE` — and a mapping
# guessed from the container name would report `unrecorded` forever for exactly
# the services whose names are irregular.
#
# Upstream images are not here on purpose. Traefik, Postgres, Loki, Promtail and
# pgAdmin are pinned in `docker-compose.yml` to a version this organisation did
# not build, so there is no record of intent for them to drift from.
SERVICES=(
    "api:API_IMAGE"
    "verifier-runner:RUNNER_IMAGE"
    "moderation-runner:MODERATION_IMAGE"
    "support-triage-runner:TRIAGE_IMAGE"
    "badge-runner:BADGE_IMAGE"
    "website:WEBSITE_IMAGE"
)

docker_cmd() {
    # Same reasoning as health-report.sh and deployed-revision.sh, including the
    # `</dev/null`: without it the docker CLI eats the stdin of the calling loop
    # and the report covers one service while looking complete.
    if docker info >/dev/null 2>&1; then
        docker "$@" </dev/null
    else
        sudo -n docker "$@" </dev/null
    fi
}

# The record, read in a subshell so that sourcing a file of `NAME=value` lines
# cannot overwrite anything this script relies on.
#
# **A missing file is not an empty one.** No `deployed.env` means this host has
# never completed a deploy since immutable pinning was introduced, which is what
# `rollback.sh` already refuses to act on. Reporting every service as
# `unrecorded` says exactly that, one row at a time, and lets the triage decide
# — rather than exiting here and leaving the caller with no rows, which is the
# shape both existing triages read as a broken watcher.
recorded_ref_for() {
    local var="$1"
    [ -f "$STATE_FILE" ] || { echo "-"; return; }
    (
        set -a
        # shellcheck disable=SC1090
        . "$STATE_FILE" >/dev/null 2>&1
        set +a
        printf '%s\n' "${!var:-}"
    )
}

for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    var="${entry##*:}"
    container="kolonie-${svc}"

    recorded_ref=$(recorded_ref_for "$var")
    [ -z "$recorded_ref" ] && recorded_ref="-"

    # The recorded reference resolved to the local image id. `deployed.env` holds
    # a registry manifest digest (`repo@sha256:…`) and a container reports a
    # *local* image id — different hashes of different things, so they can never
    # be compared as strings. Asking Docker to resolve the reference is what puts
    # both sides in the same vocabulary.
    #
    # This reads the local image store only. If the recorded image is not present
    # the answer is `-` and this script says so, rather than reaching for the
    # registry: a check that needs the network to run is a check that reports
    # `unknown` during exactly the outages worth watching.
    recorded_id="-"
    if [ "$recorded_ref" != "-" ]; then
        recorded_id=$(docker_cmd image inspect "$recorded_ref" --format '{{.Id}}' 2>/dev/null)
    fi

    running_id=$(docker_cmd inspect "$container" --format '{{.Image}}' 2>/dev/null)

    case "$recorded_id" in "<no value>"|"map[]"|"") recorded_id="-" ;; esac
    case "$running_id"  in "<no value>"|"map[]"|"") running_id="-"  ;; esac

    printf '%s\t%s\t%s\t%s\n' "$svc" "$recorded_ref" "$recorded_id" "$running_id"
done

exit 0
