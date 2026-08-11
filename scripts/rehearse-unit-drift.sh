#!/bin/bash
# Rehearse the unit-drift rows without a deploy host (#126).
#
# Both sides, as every other rehearsal here does: the measurement in
# health-report.sh and the judgement in health-triage.sh. The real thing compares
# /opt/kolonie/systemd against /etc/systemd/system; here both directories are
# temporary, which is what `KOLONIE_DEPLOY_DIR` and `KOLONIE_UNIT_DIR` exist for.
#
# **The cases that must *not* fire are half the point.** A detector that reported
# drift on a unit that matches would be muted within a week, and the whole reason
# #126 exists is that nine of ten units were fine and nothing said which nine.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
DEPLOY="$WORK/deploy"
UNITS="$WORK/etc"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN" "$DEPLOY/systemd" "$UNITS"

FAILED=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n' "$1"
    [ -n "${2-}" ] && printf '       %s\n' "$2"
    FAILED=1
}

# Enough of a host that health-report.sh reaches the unit block. Docker answers
# nothing and systemctl lists no timers; neither is what this rehearses.
cat > "$BIN/docker" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN"/*
: > "$DEPLOY/docker-compose.yml"

report() {
    PATH="$BIN:$PATH" \
        KOLONIE_DEPLOY_DIR="$DEPLOY" \
        KOLONIE_UNIT_DIR="$UNITS" \
        bash "$ROOT/scripts/health-report.sh" 2>/dev/null
}

row() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n'; }

# --- a unit the host has, byte for byte -------------------------------------
printf '[Unit]\nDescription=A unit that matches\n' > "$DEPLOY/systemd/kolonie-matching.service"
cp "$DEPLOY/systemd/kolonie-matching.service" "$UNITS/kolonie-matching.service"

out=$(report)
if [ "$(row "$out" 'unit:kolonie-matching.service' | cut -f2)" = ok ]; then
    pass "a unit whose host copy is identical reports ok"
else
    fail "a unit whose host copy is identical reports ok" "$out"
fi

# --- the #119 shape: one line gained here and never installed ----------------
printf '[Unit]\nDescription=A unit that drifted\n[Service]\nStateDirectory=kolonie\n' \
    > "$DEPLOY/systemd/kolonie-drifting.service"
printf '[Unit]\nDescription=A unit that drifted\n' > "$UNITS/kolonie-drifting.service"

out=$(report)
if [ "$(row "$out" 'unit:kolonie-drifting.service' | cut -f2)" = drifted ]; then
    pass "a unit whose host copy differs reports drifted"
else
    fail "a unit whose host copy differs reports drifted" "$out"
fi

# --- carried here, never installed at all -----------------------------------
printf '[Timer]\nOnCalendar=daily\n' > "$DEPLOY/systemd/kolonie-uninstalled.timer"

out=$(report)
if [ "$(row "$out" 'unit:kolonie-uninstalled.timer' | cut -f2)" = absent ]; then
    pass "a unit the host has never had reports absent, not drifted"
else
    fail "a unit the host has never had reports absent, not drifted" "$out"
fi

# --- the judgement ----------------------------------------------------------
verdict=$(printf '%s\n' "$out" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null)

for expected in 'kolonie-drifting.service` | drifted' 'kolonie-uninstalled.timer` | absent' \
    'Nothing deploys'; do
    if printf '%s\n' "$verdict" | grep -qF "$expected"; then
        pass "the verdict names $expected"
    else
        fail "the verdict names $expected" "$verdict"
    fi
done

# **Read the diff before copying** — the host's copy may be the right one, and a
# remedy that only ever says *overwrite* loses a fix somebody made under pressure.
if printf '%s\n' "$verdict" | grep -q 'diff -u'; then
    pass "the remedy offers a diff before a copy"
else
    fail "the remedy offers a diff before a copy" "$verdict"
fi

# The matching unit must not appear as a problem. A detector that cries about a
# unit that is fine is a detector nobody reads.
if printf '%s\n' "$verdict" | grep -q 'kolonie-matching.service` |'; then
    fail "a matching unit stays out of the problem table" "$verdict"
else
    pass "a matching unit stays out of the problem table"
fi

# --- a checkout with no units at all ----------------------------------------
rm -f "$DEPLOY"/systemd/*
out=$(report)
if [ "$(row "$out" 'unit' | cut -f2)" = none ]; then
    pass "a checkout carrying no units says so rather than staying silent"
else
    fail "a checkout carrying no units says so rather than staying silent" "$out"
fi

# --- a host with no checkout of the units ------------------------------------
# Silence, and correctly: this runs from the checkout, so no `systemd/` means
# nothing to compare rather than everything missing.
rmdir "$DEPLOY/systemd"
out=$(report)
if printf '%s\n' "$out" | grep -q '^unit'; then
    fail "no systemd/ in the checkout reports nothing at all" "$out"
else
    pass "no systemd/ in the checkout reports nothing at all"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all cases pass"
else
    echo "REHEARSAL FAILED"
fi
exit "$FAILED"
