#!/bin/bash
# Rehearse the timer rows without a host, and in particular the window a running
# service opens in them (#138).
#
# `NextElapseUSecRealtime` is empty for two different reasons and only one of
# them is a fault: a timer that has stopped scheduling (#65), and a timer whose
# `Type=oneshot` service is running right now, for which systemd has not computed
# the next elapse yet. Measured on the host 2026-08-11 — empty at 16:20:5x with
# `kolonie-pressure.service` active, populated forty seconds later on the same
# working timer.
#
# **The case that must not fire is the point of this file.** Health Watch files a
# GitHub issue from a problem row, `kolonie-pressure.timer` fires every five
# minutes, and nothing keeps the watcher's schedule and the timer's apart — so a
# false `not scheduled` is arithmetic rather than bad luck, and #135 is one that
# already happened.
#
# Both sides, as the other rehearsals here do: the measurement in
# health-report.sh and the judgement in health-triage.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
DEPLOY="$WORK/deploy"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN" "$DEPLOY"

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1"
    [ -n "${2-}" ] && printf '       %s\n' "$2"
    FAILED=1
}

: > "$DEPLOY/docker-compose.yml"
cat > "$BIN/docker" <<'EOF'
#!/bin/bash
exit 0
EOF

# A systemd stub the cases below steer with files rather than with arguments, so
# each case is three `printf`s and the stub never grows a case statement per
# scenario. `$WORK/next` is what the timer reports as its next elapse, `$WORK/
# active` what its service reports, and `$WORK/since` when that service went
# active — in the monotonic microseconds the real `show` prints.
cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
W="${REHEARSE_WORK:?}"
case "$*" in
    "list-unit-files --type=timer --no-legend kolonie-*.timer")
        printf 'kolonie-rehearsed.timer enabled enabled\n' ;;
    *"-p NextElapseUSecRealtime"*)
        cat "$W/next" 2>/dev/null || true ;;
    *"-p Unit"*)
        printf 'kolonie-rehearsed.service\n' ;;
    "is-active kolonie-rehearsed.service")
        cat "$W/active" 2>/dev/null || true ;;
    *"-p ActiveEnterTimestampMonotonic"*)
        cat "$W/since" 2>/dev/null || true ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/*

# The stub answers in monotonic time, so a case that wants "active for N seconds"
# has to be written against this host's clock rather than against a constant.
now_mono() { awk '{printf "%d", $1 * 1000000}' /proc/uptime; }
active_for() { printf '%s\n' "$(( $(now_mono) - ${1} * 1000000 ))" > "$WORK/since"; }

report() {
    PATH="$BIN:$PATH" REHEARSE_WORK="$WORK" \
        KOLONIE_DEPLOY_DIR="$DEPLOY" \
        bash "$ROOT/scripts/health-report.sh" 2>/dev/null
}

row() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n'; }

# --- a timer with a next elapse, the ordinary case --------------------------
printf 'Fri 2099-01-01 00:00:00 UTC\n' > "$WORK/next"
printf 'inactive\n' > "$WORK/active"

out=$(report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = ok ]; then
    pass "a timer with a next elapse reports ok"
else
    fail "a timer with a next elapse reports ok" "$out"
fi

# --- #65: empty, and the service is not running -----------------------------
: > "$WORK/next"
printf 'inactive\n' > "$WORK/active"

out=$(report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = not-scheduled ]; then
    pass "an empty next elapse with an idle service still reports not-scheduled"
else
    fail "an empty next elapse with an idle service still reports not-scheduled" "$out"
fi

verdict=$(printf '%s\n' "$out" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null)
if printf '%s\n' "$verdict" | grep -qF 'not scheduled'; then
    pass "the judgement calls that one a problem"
else
    fail "the judgement calls that one a problem" "$verdict"
fi

# --- #138: empty because the run is in progress -----------------------------
: > "$WORK/next"
printf 'active\n' > "$WORK/active"
active_for 20

out=$(report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = running ]; then
    pass "an empty next elapse during its own run reports running, not a fault"
else
    fail "an empty next elapse during its own run reports running, not a fault" "$out"
fi

verdict=$(printf '%s\n' "$out" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null)
if printf '%s\n' "$verdict" | grep -qF 'not scheduled'; then
    fail "the judgement does not file a problem against a timer mid-run" "$verdict"
else
    pass "the judgement does not file a problem against a timer mid-run"
fi

# `activating` is the same window: a oneshot spends its whole run there when it
# has a `ExecStartPre`, and reading it as idle would put the false row back.
printf 'activating\n' > "$WORK/active"
out=$(report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = running ]; then
    pass "activating counts as running, not as idle"
else
    fail "activating counts as running, not as idle" "$out"
fi

# --- the bound: a run that is not ending is a fault of its own ---------------
printf 'active\n' > "$WORK/active"
active_for 4000

out=$(report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = stuck ]; then
    pass "a service active far past the bound reports stuck rather than running"
else
    fail "a service active far past the bound reports stuck rather than running" "$out"
fi

verdict=$(printf '%s\n' "$out" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null)
if printf '%s\n' "$verdict" | grep -qF 'service stuck' &&
       printf '%s\n' "$verdict" | grep -qF 'kolonie-rehearsed.service'; then
    pass "the judgement names the service rather than telling anyone to reenable the timer"
else
    fail "the judgement names the service rather than telling anyone to reenable the timer" "$verdict"
fi

# --- the bound is configurable, and the row moves with it -------------------
out=$(KOLONIE_TIMER_RUN_SECONDS=9999 report)
if [ "$(row "$out" 'timer:kolonie-rehearsed.timer' | cut -f2)" = running ]; then
    pass "a longer bound keeps the same run on the healthy side"
else
    fail "a longer bound keeps the same run on the healthy side" "$out"
fi

exit "$FAILED"
