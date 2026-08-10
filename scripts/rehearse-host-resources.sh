#!/bin/bash
# Rehearse the host resource rows without a deploy host (#101).
#
# The real report reads procfs, df, sysstat and the kernel journal. Stubs make
# both sides of each alarm deterministic: measurement in health-report.sh and
# judgement in health-triage.sh.
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

cat > "$BIN/docker" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$BIN/df" <<'EOF'
#!/bin/bash
if printf '%s\n' "$@" | grep -q -- '-Pi'; then
    printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n'
    printf '/dev/root 1000 70 930 %s%% /\n' "${STUB_INODE_PERCENT:-7}"
else
    printf 'Use%%\n15%%\n'
fi
EOF

cat > "$BIN/getconf" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_CORES:-4}"
EOF

cat > "$BIN/sar" <<'EOF'
#!/bin/bash
cat <<SAR
Linux rehearsal
08:10:00 0 100 0.10 0.20 ${STUB_LOAD:-0.72} 0
08:20:00 0 100 0.10 0.20 ${STUB_LOAD:-0.72} 0
Average: 0 100 0.10 0.20 ${STUB_LOAD:-0.72} 0
SAR
EOF

cat > "$BIN/journalctl" <<'EOF'
#!/bin/bash
if [ "${STUB_JOURNAL_FAIL:-0}" = 1 ]; then
    exit 1
fi
printf '%s\n' "${STUB_JOURNAL:-kernel: routine message}"
EOF

cat > "$BIN/sudo" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF

cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$BIN"/*

report() {
    cat > "$WORK/meminfo" <<EOF
MemTotal:       ${STUB_MEM_TOTAL:-8000000} kB
MemAvailable:   ${STUB_MEM_AVAILABLE:-6200000} kB
EOF
    PATH="$BIN:$PATH" \
    KOLONIE_DEPLOY_DIR="$DEPLOY" \
    KOLONIE_BACKUP_DIR="$WORK/backups" \
    MEMINFO_PATH="$WORK/meminfo" \
        bash "$ROOT/scripts/health-report.sh" 2>/dev/null
}

resource_rows() {
    printf '%s\n' "$1" | awk -F'\t' \
        '$1 == "memory" || $1 == "inodes" || $1 == "load" || $1 == "oom"'
}

triage() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null
}

echo "rehearsing host resource alarms (#101)"

out=$(report)
rows=$(resource_rows "$out")

if printf '%s\n' "$rows" | grep -q $'memory\tok\t-\t6200000\t77\t8000000'; then
    pass "memory reports MemAvailable as a percentage of total"
else
    fail "memory reports MemAvailable as a percentage of total" "$rows"
fi

if printf '%s\n' "$rows" | grep -q $'inodes\tok\t-\t0\t7\t/var/lib/docker'; then
    pass "inode use is reported separately from byte capacity"
else
    fail "inode use is reported separately from byte capacity" "$rows"
fi

if printf '%s\n' "$rows" | grep -q $'load\tok\t4\t3600\t18\t0.72'; then
    pass "one-hour load is normalised by online core count"
else
    fail "one-hour load is normalised by online core count" "$rows"
fi

if printf '%s\n' "$rows" | grep -q $'oom\tclear\t-\t0\t0\t-'; then
    pass "a quiet kernel journal reports no OOM event"
else
    fail "a quiet kernel journal reports no OOM event" "$rows"
fi

healthy=$(triage "$rows")
if printf '%s\n' "$healthy" | grep -q '77% available' &&
    printf '%s\n' "$healthy" | grep -q '18% of capacity'; then
    pass "healthy measurements stay below their alarms"
else
    fail "healthy measurements stay below their alarms" "$healthy"
fi

out=$(STUB_MEM_AVAILABLE=1200000 STUB_INODE_PERCENT=90 STUB_LOAD=4.40 \
    STUB_JOURNAL='kernel: Out of memory: Killed process 42 (worker)' report)
rows=$(resource_rows "$out")
degraded=$(triage "$rows")

for expected in '15% available' '90% full by inode count' \
    '110% of capacity' 'out-of-memory kill event'; do
    if printf '%s\n' "$degraded" | grep -q "$expected"; then
        pass "degraded report includes $expected"
    else
        fail "degraded report includes $expected" "$degraded"
    fi
done

overridden=$(printf '%s\n' "$rows" |
    MEMORY_AVAILABLE_PERCENT=10 INODE_FULL_PERCENT=95 LOAD_SUSTAINED_PERCENT=120 \
        bash "$ROOT/scripts/health-triage.sh" 2>/dev/null)
if ! printf '%s\n' "$overridden" | grep -q '| _memory_ | low' &&
    ! printf '%s\n' "$overridden" | grep -q '| _inodes_ | filling' &&
    ! printf '%s\n' "$overridden" | grep -q '| _processor load_ | saturated' &&
    printf '%s\n' "$overridden" | grep -q 'out-of-memory kill event'; then
    pass "every numeric threshold is overridable and OOM remains an event"
else
    fail "every numeric threshold is overridable and OOM remains an event" "$overridden"
fi

out=$(STUB_JOURNAL_FAIL=1 report)
oom_row=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "oom"')
if [ "$(printf '%s' "$oom_row" | cut -f2)" = "unknown" ]; then
    pass "an unreadable kernel journal is unknown, not clear"
else
    fail "an unreadable kernel journal is unknown, not clear" "$oom_row"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all cases pass"
else
    echo "REHEARSAL FAILED"
fi
exit "$FAILED"
