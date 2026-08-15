#!/bin/bash
# Rehearse the recreate leftover row without a deploy host (#183).
#
# Every service pins container_name, so compose renames the predecessor to
# <12 hex>_<name> before recreating it. A deploy that fails part-way leaves that
# rename behind, and the row it produces has been read as an outage of the
# service twice — #96 on 2026-08-08 and #183 on 2026-08-15, both badge-runner,
# healthy on the host both times. Judgement only: no Docker daemon, no host.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1"
    [ -n "${2-}" ] && printf '       %s\n' "$2"
    FAILED=1
}

triage() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null
}

fingerprint() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>&1 >/dev/null |
        grep '^FINGERPRINT=' || true
}

container_row() { printf '%s\t%s\t%s\t0\t0\t-\n' "$1" "$2" "${3:--}"; }

echo "rehearsing the recreate leftover row (#183)"

# The row exactly as Health Watch filed it on 2026-08-15, beside the service
# itself running healthy under its own name — which is the pair that has to be
# read together, and never was.
leftover=$(container_row f16be25a578c_kolonie-badge-runner created)
live=$(container_row kolonie-badge-runner running healthy)
both=$(printf '%s\n%s' "$leftover" "$live")

out=$(triage "$both")

if printf '%s\n' "$out" | grep -q 'left behind by a recreate'; then
    pass "the leftover is named as a recreate leftover"
else
    fail "the leftover is named as a recreate leftover" "$out"
fi

if printf '%s\n' "$out" | grep -q '`kolonie-badge-runner` is the live one'; then
    pass "and the row points at the service running under its own name"
else
    fail "and the row points at the service running under its own name" "$out"
fi

if ! printf '%s\n' "$out" | grep -q 'not running |'; then
    pass "it is not filed as a service that is simply not running"
else
    fail "it is not filed as a service that is simply not running" "$out"
fi

# The advice that was printed before this change. `.State.Health` is empty for a
# container in `created` — it has no health object at all — so the one command
# offered to whoever read #96 and #183 could not answer either of them.
if ! printf '%s\n' "$out" | grep -q 'State.Health'; then
    pass "and is not sent to a health log the container does not have"
else
    fail "and is not sent to a health log the container does not have" "$out"
fi

if printf '%s\n' "$out" | grep -q 'the next' &&
    printf '%s\n' "$out" | grep -q 'build-and-deploy.yml'; then
    pass "the closing advice points at the deploy that failed"
else
    fail "the closing advice points at the deploy that failed" "$out"
fi

# The service's own row is still read on its own terms: healthy here, so it
# belongs under Healthy and not among the problems.
if printf '%s\n' "$out" | grep -q -- '- kolonie-badge-runner (healthy)'; then
    pass "the live service is still reported healthy in the same run"
else
    fail "the live service is still reported healthy in the same run" "$out"
fi

# The fingerprint decides whether the watcher files a fresh comment or closes a
# resolved issue. Renaming what the row *says* must not move it, or every open
# leftover issue is filed a second time on the first run after this change.
fp=$(fingerprint "$leftover")
if printf '%s\n' "$fp" | grep -q 'f16be25a578c_kolonie-badge-runner:created'; then
    pass "the fingerprint is unchanged, so no open issue is refiled"
else
    fail "the fingerprint is unchanged, so no open issue is refiled" "$fp"
fi

# A leftover is still a problem: it holds an image a prune would otherwise
# reclaim, and it is evidence of a deploy that did not finish. Degraded, not ok.
verdict=$(printf '%s\n' "$both" | bash "$ROOT/scripts/health-triage.sh" 2>&1 >/dev/null |
    grep '^VERDICT=')
if [ "$verdict" = "VERDICT=degraded" ]; then
    pass "a leftover still reports degraded rather than being swallowed"
else
    fail "a leftover still reports degraded rather than being swallowed" "$verdict"
fi

# --- the other half: an ordinary stopped container is untouched ------------
#
# Rehearsed as a pair for the reason the sibling scripts state — the leftover
# case alone reads as *every stopped container is housekeeping*, which is the
# opposite mistake and a worse one.
stopped=$(triage "$(container_row kolonie-api exited)")
if printf '%s\n' "$stopped" | grep -q 'not running |' &&
    printf '%s\n' "$stopped" | grep -q 'State.Health'; then
    pass "a service that is genuinely not running keeps its old row and advice"
else
    fail "a service that is genuinely not running keeps its old row and advice" "$stopped"
fi

if ! printf '%s\n' "$stopped" | grep -q 'left behind by a recreate'; then
    pass "and is not excused as a leftover"
else
    fail "and is not excused as a leftover" "$stopped"
fi

# The prefix is compose's, not a shape any service name happens to have: twelve
# hex digits and an underscore. A name that merely contains an underscore, or
# one whose prefix is the wrong length or not hex, is an ordinary container.
for name in kolonie_badge_runner badge-runner_2 f16be25a578_kolonie-api \
    f16be25a578cd_kolonie-api g16be25a578c_kolonie-api; do
    if ! printf '%s\n' "$(triage "$(container_row "$name" exited)")" |
        grep -q 'left behind by a recreate'; then
        pass "$name is not mistaken for a recreate leftover"
    else
        fail "$name is not mistaken for a recreate leftover"
    fi
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all cases pass"
else
    echo "REHEARSAL FAILED"
fi
exit "$FAILED"
