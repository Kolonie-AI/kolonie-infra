#!/bin/bash
# Turn what a caller asked to deploy into the order it must be deployed in.
#
# Reads one argument — `all`, one service name, or a comma-separated list — and
# prints the services one per line, in dependency order. Unknown names are a
# failure, not a silent skip.
#
# ## Why this exists as a file rather than as ten lines inside deploy.yml
#
# It is the only piece of #31's fix that has a wrong answer worth catching in a
# test. The rest of that change is a loop; this is a policy, and the policy is
# **the api goes first**.
#
# `migrate()` and the Academy seed run out of the api image (deploy.sh). A runner
# started before the api has therefore been started against a schema that has not
# moved yet — which on 2026-07-29 meant kolonie-moderation-runner looping on
# `relation "task_struggles" does not exist` until a human restarted it, and on
# 2026-07-30 meant a verifier-runner compiled against a table its own migration
# had not created. There is no version of that which is survivable by luck twice.
#
# The website depends on nothing and is deployed last for that reason: if
# anything in this sequence is going to fail, it should fail before the public
# face of the Colony changes.

set -euo pipefail

# The order. Adding a service means adding it here, in the position its
# dependencies require — not at the end because that is where there is room.
#
# `support-triage-runner` (kolonie-platform#105) sits with the other two runners
# and behind the api for the same reason they do: it reads and writes
# `support_tickets` through packages/db, so a build started before the api has
# been started against a schema that has not moved yet.
# `badge-runner` (kolonie-platform#241) goes with the runners and behind the api
# for the same reason: it reads and writes badge rows through packages/db, so a
# build started before the api has been started against a schema that has not
# moved yet.
readonly ORDER=(api verifier-runner moderation-runner support-triage-runner badge-runner doctor-runner website)

usage() {
    echo "usage: $(basename "$0") all|<service>[,<service>...]" >&2
    echo "services, in deploy order: ${ORDER[*]}" >&2
}

if [ $# -ne 1 ] || [ -z "$1" ]; then
    usage
    exit 2
fi

requested="$1"

# `all` is not a list of every service — it is deploy.sh's own mode, in which it
# brings up the whole compose project including the infrastructure containers.
# Expanding it here into four single-service deploys would be a different and
# worse thing: four pulls, four health checks, and no `--remove-orphans`.
if [ "$requested" = all ]; then
    echo all
    exit 0
fi

selected=()
for candidate in "${ORDER[@]}"; do
    case ",${requested}," in
        *,"${candidate}",*) selected+=("$candidate") ;;
    esac
done

# Every name the caller passed has to have matched something. A list containing
# one typo would otherwise deploy the rest and report success — the silent
# partial deploy this whole issue is about, reintroduced one level up.
IFS=',' read -r -a given <<< "$requested"
for name in "${given[@]}"; do
    [ -z "$name" ] && continue
    matched=false
    for candidate in "${ORDER[@]}"; do
        [ "$name" = "$candidate" ] && matched=true && break
    done
    if [ "$matched" = false ]; then
        echo "ERROR: '$name' is not a deployable service" >&2
        usage
        exit 1
    fi
done

if [ ${#selected[@]} -eq 0 ]; then
    echo "ERROR: '$requested' names nothing deployable" >&2
    usage
    exit 1
fi

printf '%s\n' "${selected[@]}"
