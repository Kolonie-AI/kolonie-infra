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

# --- the verdict the row earns (#198) --------------------------------------
#
# The rejection case first, and deliberately: a change that let a real outage be
# relabelled housekeeping because a rename happened to be lying around beside it
# would be worse than the defect it fixes. Severity follows the worst row.
verdict_of() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>&1 >/dev/null |
        grep '^VERDICT='
}

status_of() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" >/dev/null 2>&1
    printf '%s' "$?"
}

unhealthy=$(container_row kolonie-api running unhealthy)
mixed=$(printf '%s\n%s\n%s' "$leftover" "$live" "$unhealthy")

got=$(verdict_of "$mixed")
if [ "$got" = "VERDICT=degraded" ]; then
    pass "a leftover beside a genuinely unhealthy container is still degraded"
else
    fail "a leftover beside a genuinely unhealthy container is still degraded" "$got"
fi

# Which is what puts it on the outage thread rather than the housekeeping one:
# the workflow picks the title from the verdict, and the create must not name a
# title of its own. Hardcoding it there is the whole of #197.
watch="$ROOT/.github/workflows/health-watch.yml"
if grep -q -- '--title "\$active_title"' "$watch" &&
    ! grep -q -- '--title "\$ISSUE_TITLE"' "$watch"; then
    pass "and the workflow files it under the title the verdict chose"
else
    fail "and the workflow files it under the title the verdict chose" \
        "$(grep -n -- '--title' "$watch")"
fi

# A leftover alone is not an outage. It is still a finding — one that is still
# there tomorrow means a deploy failed part-way — so it is reported, and the exit
# code stays 1 so that no caller reads it as silence.
got=$(verdict_of "$both")
if [ "$got" = "VERDICT=housekeeping" ]; then
    pass "a leftover on its own is housekeeping rather than an outage"
else
    fail "a leftover on its own is housekeeping rather than an outage" "$got"
fi

got=$(status_of "$both")
if [ "$got" = "1" ]; then
    pass "and it still exits 1, because there is a finding to report"
else
    fail "and it still exits 1, because there is a finding to report" "exit=$got"
fi

# The healthy case is not disturbed by any of the above: no rows, no verdict but
# ok, and the exit code the callers branch on.
got=$(verdict_of "$live")
if [ "$got" = "VERDICT=ok" ]; then
    pass "a host with no problem rows still reports ok"
else
    fail "a host with no problem rows still reports ok" "$got"
fi

got=$(status_of "$live")
if [ "$got" = "0" ]; then
    pass "and exits 0"
else
    fail "and exits 0" "exit=$got"
fi

# Two leftovers are two rows on one report, not two reports: the workflow files
# per thread and per fingerprint, so what has to hold here is that both rows land
# in one summary under one verdict.
second=$(container_row a1b2c3d4e5f6_kolonie-api created)
pair=$(printf '%s\n%s\n%s' "$leftover" "$second" "$live")
out=$(triage "$pair")
rows=$(printf '%s\n' "$out" | grep -c 'left behind by a recreate')
got=$(verdict_of "$pair")
if [ "$rows" = "2" ] && [ "$got" = "VERDICT=housekeeping" ]; then
    pass "two leftovers are one housekeeping report with two rows"
else
    fail "two leftovers are one housekeeping report with two rows" "rows=$rows $got"
fi

# And the fingerprint does not depend on the order the daemon happened to list
# them in, or every reordering would read as a new situation and file again.
reversed=$(printf '%s\n%s\n%s' "$second" "$live" "$leftover")
if [ "$(fingerprint "$pair")" = "$(fingerprint "$reversed")" ]; then
    pass "and the same rows in another order are the same fingerprint"
else
    fail "and the same rows in another order are the same fingerprint" \
        "$(fingerprint "$pair") vs $(fingerprint "$reversed")"
fi

# The verdict is only worth anything if it survives the step that reads it. All
# three go through `verdict-out.sh` onto a real `$GITHUB_OUTPUT` here, because a
# third verdict is exactly the kind of change that passes its own test and then
# fails at the whitelist in the workflow — which is #163, and how a healthy host
# took the reporting step down with it.
carried() {
    local out
    out=$(mktemp)
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" >/dev/null 2>"$out.err"
    GITHUB_OUTPUT="$out" bash "$ROOT/scripts/verdict-out.sh" "$out.err" >/dev/null 2>&1
    grep '^VERDICT=' "$out" || true
    rm -f "$out" "$out.err"
}

for probe in "$live:ok" "$both:housekeeping" "$mixed:degraded"; do
    want="VERDICT=${probe##*:}"
    got=$(carried "${probe%:*}")
    if [ "$got" = "$want" ]; then
        pass "$want reaches the step output through verdict-out.sh"
    else
        fail "$want reaches the step output through verdict-out.sh" "$got"
    fi
done

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
