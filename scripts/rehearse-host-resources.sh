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
if [ "${1:-}" = info ]; then exit 0; fi
if [ "${1:-} ${2:-}" = "system df" ]; then
    [ "${STUB_DOCKER_DF_FAIL:-0}" = 1 ] && exit 1
    printf 'Images\t10.31GB\t6.634GB (64%%)\n'
fi
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
if [ "${1:-}" = show ]; then
    case "$2:$4" in
        kolonie-image-prune.timer:LoadState) printf '%s\n' "${STUB_PRUNE_LOAD:-loaded}" ;;
        kolonie-image-prune.service:Result) printf '%s\n' "${STUB_PRUNE_RESULT:-success}" ;;
    esac
fi
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
    KOLONIE_STATE_DIR="$DEPLOY/state" \
    MEMINFO_PATH="$WORK/meminfo" \
        bash "$ROOT/scripts/health-report.sh" 2>/dev/null
}

resource_rows() {
    printf '%s\n' "$1" | awk -F'\t' \
        '$1 == "disk" || $1 == "image-prune" || $1 == "memory" || $1 == "inodes" || $1 == "load" || $1 == "oom"'
}

triage() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>/dev/null
}

echo "rehearsing host resource alarms (#101)"

mkdir -p "$DEPLOY/state"
printf 'LAST_SUCCESS_EPOCH=%s\nLAST_FREED_BYTES=2000000000\n' \
    "$(( $(date +%s) - 3600 ))" > "$DEPLOY/state/image-prune.env"

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

if printf '%s\n' "$rows" | grep -q $'disk\tok\t-\t6634000000\t15\t10310000000'; then
    pass "disk reports reclaimable image bytes beside partition use"
else
    fail "disk reports reclaimable image bytes beside partition use" "$rows"
fi

if printf '%s\n' "$rows" | grep -q $'image-prune\tok\t-\t2000000000\t'; then
    pass "the last successful prune remains visible between weekly runs"
else
    fail "the last successful prune remains visible between weekly runs" "$rows"
fi

healthy=$(triage "$rows")
if printf '%s\n' "$healthy" | grep -q '77% available' &&
    printf '%s\n' "$healthy" | grep -q '18% of capacity' &&
    printf '%s\n' "$healthy" | grep -q '6.2 GiB of 9.6 GiB in images reclaimable' &&
    printf '%s\n' "$healthy" | grep -q '1.9 GiB freed'; then
    pass "healthy measurements stay below their alarms"
else
    fail "healthy measurements stay below their alarms" "$healthy"
fi

out=$(STUB_PRUNE_LOAD=not-found report)
degraded=$(triage "$(resource_rows "$out")")
if printf '%s\n' "$degraded" | grep -q 'weekly timer is not installed'; then
    pass "a missing image-prune timer is visible"
else
    fail "a missing image-prune timer is visible" "$degraded"
fi

out=$(STUB_PRUNE_RESULT=exit-code report)
degraded=$(triage "$(resource_rows "$out")")
if printf '%s\n' "$degraded" | grep -q 'timer ran, but its service failed'; then
    pass "a failed scheduled prune is visible"
else
    fail "a failed scheduled prune is visible" "$degraded"
fi

printf 'LAST_SUCCESS_EPOCH=%s\nLAST_FREED_BYTES=2000000000\n' \
    "$(( $(date +%s) - 691200 ))" > "$DEPLOY/state/image-prune.env"
out=$(report)
degraded=$(triage "$(resource_rows "$out")")
if printf '%s\n' "$degraded" | grep -q 'last successful prune was 8d ago'; then
    pass "a missed weekly prune becomes stale after eight days"
else
    fail "a missed weekly prune becomes stale after eight days" "$degraded"
fi
printf 'LAST_SUCCESS_EPOCH=%s\nLAST_FREED_BYTES=2000000000\n' \
    "$(( $(date +%s) - 3600 ))" > "$DEPLOY/state/image-prune.env"

out=$(STUB_DOCKER_DF_FAIL=1 report)
degraded=$(triage "$(resource_rows "$out")")
if printf '%s\n' "$degraded" | grep -q 'Docker did not report reclaimable image storage'; then
    pass "missing reclaimable-image data is unknown, not zero"
else
    fail "missing reclaimable-image data is unknown, not zero" "$degraded"
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

# --- a partial disk row is judged on its percentage (#158) ----------------
#
# Rehearsed as a **pair**, above and below the threshold, for the reason
# `rehearse-pressure.sh` states about the same line one script over: the
# below-threshold case alone reads as *partial is fine*, and the above-threshold
# case alone reads as *partial is always an alarm*. Neither is the rule.
#
# `partial` is `df` answering and `docker system df` not — every deploy. Before
# this, it returned before the threshold was compared, so a partition at 92 %
# during a deploy was filed as *image storage unknown*, with the fingerprint
# that decides whether a fresh comment is filed saying the lesser thing.
disk_row() { printf 'disk\t%s\t-\t0\t%s\t-\n' "$1" "$2"; }

filling=$(triage "$(disk_row partial 92)")
if printf '%s\n' "$filling" | grep -q '| _disk_ | filling |' &&
    printf '%s\n' "$filling" | grep -q '92% full'; then
    pass "a partial row at 92% is filed as filling, not as image-storage-unknown"
else
    fail "a partial row at 92% is filed as filling, not as image-storage-unknown" "$filling"
fi

if printf '%s\n' "$filling" | grep -q 'did not report reclaimable image storage'; then
    pass "and still says the image figure is missing, on that same row"
else
    fail "and still says the image figure is missing, on that same row" "$filling"
fi

# The criterion the issue is actually about. The fingerprint is what decides
# whether a fresh comment is filed, so a disk that crosses the threshold during
# a deploy and stays there once the deploy ends — `partial` becoming `ok` at the
# same percentage — must not be filed twice.
#
# The fingerprint is on stderr, which is where the triage scripts put the two
# lines the workflow reads.
fingerprint() {
    printf '%s\n' "$1" | bash "$ROOT/scripts/health-triage.sh" 2>&1 >/dev/null |
        grep '^FINGERPRINT=' || true
}
fp_partial=$(fingerprint "$(disk_row partial 92)")
fp_ok=$(fingerprint "$(disk_row ok 92)")
if [ "$fp_partial" = "$fp_ok" ] && [ "$fp_partial" = "FINGERPRINT=disk:full" ]; then
    pass "a partial and an ok row at 92% share the one fingerprint disk:full"
else
    fail "a partial and an ok row at 92% share the one fingerprint disk:full" \
        "$(printf 'partial: %s\nok:      %s' "$fp_partial" "$fp_ok")"
fi

below=$(triage "$(disk_row partial 40)")
if printf '%s\n' "$below" | grep -q 'but Docker did not report reclaimable image storage' &&
    ! printf '%s\n' "$below" | grep -q '| _disk_ | filling |'; then
    pass "a partial row below the threshold reports exactly what it reported before"
else
    fail "a partial row below the threshold reports exactly what it reported before" "$below"
fi

# `unknown` is untouched and must not fall through to the numeric test:
# `health-report.sh` writes `0` in the percentage column when `df` did not
# answer, and 0 is below every threshold there will ever be (#103).
unknown=$(triage "$(disk_row unknown 0)")
if printf '%s\n' "$unknown" | grep -q 'could not report how full its partition is'; then
    pass "unknown is untouched and does not read as an empty disk"
else
    fail "unknown is untouched and does not read as an empty disk" "$unknown"
fi

# Reachable only now that a partial row gets as far as the comparison, so this
# guard is part of the same change: `[ - -ge 90 ]` is a bash diagnostic on
# stderr, and stderr is the verdict channel (#163).
notanumber=$(triage "$(disk_row partial -)")
if printf '%s\n' "$notanumber" | grep -q '| _disk_ | unknown |' &&
    ! printf '%s\n' "$notanumber" | grep -q '| _disk_ | filling |'; then
    pass "a partial row whose percentage is not a number is unknown, not filling"
else
    fail "a partial row whose percentage is not a number is unknown, not filling" "$notanumber"
fi

# And it says so quietly — nothing on stderr, because stderr is where the
# verdict lives and a bash diagnostic there kills the step that reads it.
noise=$(printf '%s\n' "$(disk_row partial -)" |
    bash "$ROOT/scripts/health-triage.sh" 2>&1 >/dev/null |
    grep -v '^VERDICT=' | grep -v '^FINGERPRINT=' || true)
if [ -z "$noise" ]; then
    pass "and writes nothing but its verdict to the channel the workflow reads"
else
    fail "and writes nothing but its verdict to the channel the workflow reads" "$noise"
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
