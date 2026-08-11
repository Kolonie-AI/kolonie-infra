#!/bin/bash
# Rehearse pressure-report.sh against a stub host report. `kolonie-infra#103`.
#
# Usage: ./scripts/rehearse-pressure.sh
#
# **The direction that matters is the quiet one.** This publishes a keyword an
# external monitor alerts on the *absence* of, so every way this script can fail
# to notice pressure is an alarm that does not ring — and a health check that
# stays quiet when it cannot see is the failure `#103` exists against. Half of
# these cases are therefore about what happens when the report is missing,
# truncated, or carrying something that is not a number.
#
# The three conditions `#103` puts on the alerting side of the line are asserted
# individually, and so is every condition it deliberately leaves on the issue
# side: a container reporting unhealthy must **not** raise this.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/pressure-report.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/pressure.json"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }

# A stub `health-report.sh` printing whatever the case put in `rows`.
cat > "$WORK/report.sh" <<'STUB'
#!/bin/bash
cat "$ROWS" 2>/dev/null
exit 0
STUB
chmod +x "$WORK/report.sh"
export ROWS="$WORK/rows.tsv"

verdict() {
  printf '%s\n' "$1" > "$ROWS"
  rm -f "$OUT"
  PRESSURE_REPORT_CMD="$WORK/report.sh" bash "$SCRIPT" "$OUT" >/dev/null 2>&1
  jq -r '.status' "$OUT" 2>/dev/null || echo "(no file)"
}

# A healthy host: well under both thresholds, backed up two hours ago, and one
# container that is not well — which belongs on the issue side of the line.
healthy=$'disk\tok\t-\t9345000000\t18\t9345000000
inodes\tok\t-\t0\t10\t/var/lib/docker
backup\tok\t-\t0\t7200\t-
memory\tok\t-\t6288032\t77\t8126536'

echo "== the three conditions that reach a person =="
check "a healthy host publishes the keyword" "$(verdict "$healthy")" "ok"
check "a disk at the threshold does not" \
  "$(verdict "${healthy/$'disk\tok\t-\t9345000000\t18'/$'disk\tok\t-\t9345000000\t85'}")" "degraded"
check "a disk one under it still does" \
  "$(verdict "${healthy/$'disk\tok\t-\t9345000000\t18'/$'disk\tok\t-\t9345000000\t84'}")" "ok"
check "exhausted inodes do not — the disk that does not look full (#101)" \
  "$(verdict "${healthy/$'inodes\tok\t-\t0\t10'/$'inodes\tok\t-\t0\t97'}")" "degraded"
check "a backup older than the stale window does not" \
  "$(verdict "${healthy/$'backup\tok\t-\t0\t7200'/$'backup\tok\t-\t0\t200000'}")" "degraded"
check "and a backup that has never run does not" \
  "$(verdict "${healthy/$'backup\tok\t-\t0\t7200'/$'backup\tnever\t-\t0\t0'}")" "degraded"

echo "== what #103 leaves on the issue side, and this must not page for =="
check "an unhealthy container does not raise it" \
  "$(verdict "$healthy"$'\nkolonie-api\trunning\tunhealthy\t3\t0\tsha256:abc')" "ok"
check "nor does memory pressure" \
  "$(verdict "${healthy/$'memory\tok\t-\t6288032\t77'/$'memory\tok\t-\t100\t2'}")" "ok"

echo "== the quiet failures, which are the dangerous ones =="
check "an empty report is pressure, not health" "$(verdict "")" "degraded"
check "a report with no disk row at all is pressure" \
  "$(verdict $'memory\tok\t-\t1\t50\t2')" "degraded"
check "a percentage that is not a number is pressure" \
  "$(verdict "${healthy/$'disk\tok\t-\t9345000000\t18'/$'disk\tok\t-\t9345000000\t?'}")" "degraded"
check "a disk row the host could not fully read is pressure" \
  "$(verdict "${healthy/$'disk\tok\t-\t9345000000\t18'/$'disk\tpartial\t-\t0\t18'}")" "degraded"
check "and an unknown inode reading is pressure" \
  "$(verdict "${healthy/$'inodes\tok\t-\t0\t10'/$'inodes\tunknown\t-\t0\t-'}")" "degraded"

echo "== the file itself =="
verdict "$healthy" >/dev/null
check "it is readable by the server that has to serve it" "$(stat -c '%a' "$OUT")" "644"
check "it is valid JSON" "$(jq -e 'has("status")' "$OUT" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "it carries no number" \
  "$(grep -qE '[0-9]' "$OUT" && echo leaked || echo clean)" "clean"
check "it carries the keyword the account already matches on" \
  "$(grep -qF '"status":"ok"' "$OUT" && echo yes || echo no)" "yes"

# A degraded host must not exit non-zero: systemd would mark the unit failed and
# `health-report.sh` would then carry a second alarm about the timer, on top of
# the one the missing keyword already raises.
printf '%s\n' "" > "$ROWS"
PRESSURE_REPORT_CMD="$WORK/report.sh" bash "$SCRIPT" "$OUT" >/dev/null 2>&1
check "a degraded verdict still exits 0" "$?" "0"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
