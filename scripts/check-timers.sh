#!/bin/bash
# Kolonie AI — no timer here may schedule only from its own history (#130)
#
# `kolonie-pressure.timer` stopped scheduling and reported itself healthy by
# every signal anybody would think to check: `is-active` active, `is-enabled`
# enabled, the last run successful, the `timers.target.wants` symlink present.
# The only field that told the truth was `NextElapseUSecRealtime`, empty — which
# is #65's signature and what #66's row exists to catch.
#
# **The cause is in the unit file and it is a class, not an incident.**
# `OnUnitActiveSec` computes the next elapse from the unit's *last activation*
# and `OnBootSec` from boot. Once boot is long past and the last activation is
# further back than the interval, both are in the past, there is no future
# elapse to compute, and the timer is silent until a reboot. It was the only one
# of six here driven that way and the only one that went quiet.
#
# A calendar expression cannot reach that state: it always has a next
# occurrence, whatever happened before. So the rule this asserts is narrow and
# absolute — **every timer in `systemd/` names an `OnCalendar`** — and it is
# asserted here rather than remembered, because the next person to add a timer
# will reach for whichever example they open first.
#
# What it deliberately does not do: judge the *interval*. Five minutes or five
# days is a decision about what the timer maintains, argued in the unit's own
# comment. This only refuses the one arrangement that can stop scheduling
# without saying so.
#
# Usage:
#   ./scripts/check-timers.sh
#
# Needs nothing but the checkout. No host, no Docker, no systemd.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

shopt -s nullglob
timers=("$ROOT"/systemd/*.timer)

# Silence must not read as success — the same rule every enumerated check here
# follows. A `systemd/` that has lost its timers is a finding.
if [ "${#timers[@]}" -eq 0 ]; then
    printf 'FAIL systemd/ carries no timer units at all\n'
    exit 1
fi

for timer in "${timers[@]}"; do
    name=$(basename "$timer")

    # Comments are stripped first. Every one of these units explains itself at
    # length, and a directive named in prose is not a directive — the whole
    # point of #130's unit was that its *comment* described a five-minute cadence
    # it had stopped keeping.
    directives=$(sed 's/#.*//' "$timer")

    if printf '%s' "$directives" | grep -qE '^[[:space:]]*OnCalendar[[:space:]]*='; then
        printf 'ok   %s names an OnCalendar\n' "$name"
    else
        printf 'FAIL %s has no OnCalendar — a timer driven only by OnBootSec or\n' "$name"
        printf '     OnUnitActiveSec stops scheduling once both are in the past, and\n'
        printf '     reports itself active, enabled and successful while it does (#130).\n'
        FAILED=1
    fi
done

if [ "$FAILED" -eq 0 ]; then
    printf '\nevery timer schedules from a calendar\n'
else
    printf '\nTIMER CHECK FAILED\n'
fi
exit "$FAILED"
