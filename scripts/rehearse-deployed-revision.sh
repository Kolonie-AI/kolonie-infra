#!/bin/bash
# Rehearse deployed-revision.sh without Docker or a host (#99).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The same list the script under test reads, so this rehearsal counts rows
# against the declaration rather than against a number written down twice.
# shellcheck source=scripts/services.sh
. "$ROOT/scripts/services.sh"
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN"

cat > "$BIN/docker" <<'STUB'
#!/bin/bash
if [ "$1" = info ]; then
  exit 0
fi
if [ "$1" = ps ]; then
  [ "${FAIL_LIST:-}" = 1 ] && exit 1
  printf '%s\n' kolonie-api kolonie-verifier-runner
  exit 0
fi
if [ "$1" = inspect ]; then
  container=$2
  [ "${FAIL_INSPECT:-}" = "$container" ] && exit 1
  case "$container" in
    kolonie-api) printf 'row\tabc123\tapi-image\n' ;;
    kolonie-verifier-runner) printf 'row\t\tverifier-image\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
echo "STUB: unexpected docker call: $*" >&2
exit 125
STUB
chmod +x "$BIN/docker"

probe() {
  PATH="$BIN:$PATH" "$@" bash "$ROOT/scripts/deployed-revision.sh"
}

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }

echo "== 1. a complete Docker read produces one row per service"
out=$(probe 2>"$WORK/error"); status=$?
check "exit 0" "$status" "0"
# One row per name in `scripts/services.sh`, which is the point of #107 — the
# count moves when a service is added, and this is the assertion that notices.
check "one row per declared service" "$(wc -l <<<"$out")" "${#KOLONIE_SERVICES[@]}"
contains "$out" $'api\tabc123\tapi-image' "reported the revision and image together"
contains "$out" $'verifier-runner\t-\tverifier-image' "normalised an absent label"
contains "$out" $'website\t-\t-' "reported an absent container"

echo "== 2. failure to list containers is a probe failure, not an empty report"
out=$(probe env FAIL_LIST=1 2>"$WORK/error"); status=$?
check "exit 2" "$status" "2"
check "stdout is empty" "$out" ""
contains "$(cat "$WORK/error")" "could not list containers" "said which Docker read failed"

echo "== 3. failure partway through inspection emits no partial report"
out=$(probe env FAIL_INSPECT=kolonie-verifier-runner 2>"$WORK/error"); status=$?
check "exit 2" "$status" "2"
check "stdout is empty" "$out" ""
contains "$(cat "$WORK/error")" "could not inspect kolonie-verifier-runner" "named the failed container"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
