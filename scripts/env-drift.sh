#!/bin/bash
# Kolonie AI — environment drift check (#8)
#
# Compares three lists that are supposed to agree and never quite do:
#
#   1. what docker-compose.yml actually reads     ${VAR} / ${VAR:-…} / ${VAR:?…}
#   2. what .env.example documents                the template an operator follows
#   3. what the deploy host defines               .env, when one is present
#
# The drift between 2 and 3 is what #8 was opened for. The drift that actually
# breaks a deploy is between 1 and 3, and #7 is what that looks like: a variable
# marked required with :? that the host does not define, discovered by every
# deploy failing for a week and being misread as a registry problem each time.
#
# **This script never prints a value.** It reads variable *names* out of .env and
# compares them. It is run by the Diagnose VPS workflow, whose log is public, and
# by anyone with a checkout. Keep it that way: adding a value to the output here
# publishes a production secret to a place that cannot be unpublished.
#
# Usage:
#   ./scripts/env-drift.sh                 compare the template against compose
#   ./scripts/env-drift.sh /opt/kolonie    …and against that directory's .env
#
# Exit status is the point, so it can gate something later:
#   0  no drift that breaks anything
#   1  a variable a service reads is undocumented, or required and undefined
#
# It needs a compose file and a template. A host .env is optional — without one
# the first two lists are still checked, which is what a contributor with no
# access to the host can usefully run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
EXAMPLE="$ROOT/.env.example"
ENV_DIR="${1:-}"

for required in "$COMPOSE" "$EXAMPLE"; do
    if [ ! -f "$required" ]; then
        echo "FAIL: $required not found — run this from a kolonie-infra checkout"
        exit 1
    fi
done

# Every ${VAR} the compose file interpolates, whatever the default syntax after
# it. Image tags are included on purpose: RUNNER_IMAGE unset is how a deploy
# silently ships :latest, which #12 and #15 are both about.
read_by_compose() {
    grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$COMPOSE" | sed 's/\${//' | sort -u
}

# Variables compose refuses to run without — ${VAR:?message}. These are the ones
# whose absence is a hard deploy failure rather than an empty string.
required_by_compose() {
    grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?' "$COMPOSE" | sed 's/\${//; s/:?//' | sort -u
}

# Both halves of the template count as documented: an active KEY= line, and a
# commented #KEY= line, which is how .env.example marks a variable that is
# genuinely optional because compose carries its production default. Treating a
# commented line as undocumented would report CAPABILITY_PAGE_URL as drift on
# every run, and a check that is wrong every run is a check people stop reading.
documented() {
    grep -oE '^#?[A-Za-z_][A-Za-z0-9_]*=' "$EXAMPLE" | tr -d '#=' | sort -u
}

# Names only. Never the right-hand side.
defined_on_host() {
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | tr -d '=' | sort -u
}

only_in_first() {
    comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

report() {
    local heading="$1" body="$2"
    echo "$heading"
    if [ -z "$body" ]; then
        echo "  (none)"
    else
        printf '%s\n' "$body" | sed 's/^/  /'
    fi
    echo
}

COMPOSE_VARS="$(read_by_compose)"
REQUIRED_VARS="$(required_by_compose)"
DOCUMENTED_VARS="$(documented)"
FAILED=0

echo "=== environment drift ==="
echo "compose reads ${COMPOSE_VARS:+$(printf '%s\n' "$COMPOSE_VARS" | wc -l)} variables, of which ${REQUIRED_VARS:+$(printf '%s\n' "$REQUIRED_VARS" | wc -l)} are required"
echo ".env.example documents $(printf '%s\n' "$DOCUMENTED_VARS" | wc -l)"
echo

UNDOCUMENTED="$(only_in_first "$COMPOSE_VARS" "$DOCUMENTED_VARS")"
report "read by a service, missing from .env.example — an operator following the template gets an empty value:" "$UNDOCUMENTED"
[ -n "$UNDOCUMENTED" ] && FAILED=1

if [ -n "$ENV_DIR" ] && [ -f "$ENV_DIR/.env" ]; then
    HOST_VARS="$(defined_on_host "$ENV_DIR/.env")"
    echo "$ENV_DIR/.env defines $(printf '%s\n' "$HOST_VARS" | wc -l)"
    echo

    MISSING_REQUIRED="$(only_in_first "$REQUIRED_VARS" "$HOST_VARS")"
    report "required by compose, absent from .env — every deploy fails, see #7:" "$MISSING_REQUIRED"
    [ -n "$MISSING_REQUIRED" ] && FAILED=1

    report "documented but not set here — fine if the compose default is meant, worth a look if not:" \
        "$(only_in_first "$DOCUMENTED_VARS" "$HOST_VARS")"

    report "set here but documented nowhere — nobody rebuilding this host would know to set it:" \
        "$(only_in_first "$HOST_VARS" "$DOCUMENTED_VARS")"

    # Reported, never failed on. A variable no service reads breaks nothing
    # today; it is how two names for one idea survive, which is the FRONTEND_URL
    # versus WEBSITE_URL half of #8. Failing on it would make the check noisy
    # about something nobody has to fix this afternoon.
    ALL_KNOWN="$(printf '%s\n%s\n' "$DOCUMENTED_VARS" "$HOST_VARS" | sort -u)"
    report "read by no service — dead weight, not a failure:" \
        "$(only_in_first "$ALL_KNOWN" "$COMPOSE_VARS")"
elif [ -n "$ENV_DIR" ]; then
    echo "no .env in $ENV_DIR — compared the template against compose only"
    echo
else
    report "documented but read by no service — dead weight, not a failure:" \
        "$(only_in_first "$DOCUMENTED_VARS" "$COMPOSE_VARS")"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK — nothing that breaks a deploy"
else
    echo "DRIFT — see the sections above"
fi

exit "$FAILED"
