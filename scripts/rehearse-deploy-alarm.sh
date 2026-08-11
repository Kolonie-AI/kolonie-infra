#!/bin/bash
# Rehearse deploy-alarm.sh without GitHub. `kolonie-infra#124`.
#
# Usage: ./scripts/rehearse-deploy-alarm.sh
#
# The property worth proving is **when it stays quiet**, not when it fires. An
# alarm that files on a transient failure is muted within a week, and a muted
# alarm is what this issue is about — the deploy pipeline was red for twenty
# hours beside a `::error::` line nobody read.
#
# `curl` is stubbed and answers from files, so the twenty-hour outage of
# 2026-08-10 can be replayed exactly, along with the two cases a live run cannot
# be made to produce on demand: a single failure, and an API that will not
# answer.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/deploy-alarm.sh"
FAILURES=()

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Answers by repository name, from a file the case wrote. Everything else about
# the request is recorded so a case can assert what was actually asked for —
# `branch=main` and `status=completed` are load-bearing and a code change could
# drop either without any assertion here noticing.
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$CURL_LOG"
case "$url" in
  *kolonie-platform*) cat "$FIX/platform.json" 2>/dev/null ;;
  *kolonie-infra*)    cat "$FIX/infra.json" 2>/dev/null ;;
  *)                  echo '{"workflow_runs":[]}' ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export FIX="$WORK/fix" CURL_LOG="$WORK/curl.log"
mkdir -p "$FIX"

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3: [$1]"; fail=$((fail+1)); fi; }

# `runs <conclusion>...` builds an answer newest-first, one run per argument,
# with a distinguishable url and timestamp per position.
runs() {
  local i=0 out=""
  for c in "$@"; do
    [ -n "$out" ] && out="$out,"
    out="$out{\"conclusion\":\"$c\",\"html_url\":\"https://example.invalid/run/$i\",\"created_at\":\"2026-08-10T0$((i % 10)):00:00Z\",\"display_title\":\"commit $i\"}"
    i=$((i + 1))
  done
  printf '{"workflow_runs":[%s]}\n' "$out"
}

run_check() {
  : > "$CURL_LOG"
  bash "$SCRIPT" check "$WORK/report.tsv" 2>"$WORK/err"
  echo $?
}

echo "== 1. a green pipeline says nothing"
runs success success success > "$FIX/platform.json"
runs success success        > "$FIX/infra.json"
check "exit 0" "$(run_check)" "0"
check "and the report is empty" "$([ ! -s "$WORK/report.tsv" ] && echo empty || cat "$WORK/report.tsv")" "empty"

echo "== 2. one failure is a flake, not an outage"
# The whole of the threshold decision. A run that failed once and has not been
# followed by anything is not evidence that the pipeline is broken.
runs failure success success > "$FIX/platform.json"
runs success success         > "$FIX/infra.json"
check "exit 0" "$(run_check)" "0"
check "nothing reported" "$([ ! -s "$WORK/report.tsv" ] && echo empty || cat "$WORK/report.tsv")" "empty"

echo "== 3. two in a row is the alarm"
runs failure failure success > "$FIX/platform.json"
runs success success         > "$FIX/infra.json"
check "exit 1" "$(run_check)" "1"
contains "$(cat "$WORK/report.tsv")" "kolonie-platform" "named the repository"
check "counted exactly two" "$(cut -f2 "$WORK/report.tsv")" "2"
# "Since when" is the question a reader asks first and the one #123 could not
# answer, so the run named is the *oldest* of the streak and never the newest.
contains "$(cat "$WORK/report.tsv")" "run/1" "named the first failing run, not the latest"

echo "== 4. the outage of 2026-08-10, replayed"
runs failure failure failure failure failure failure failure failure failure \
     failure failure failure failure success > "$FIX/platform.json"
runs failure failure failure failure failure failure success > "$FIX/infra.json"
check "exit 1" "$(run_check)" "1"
check "both repositories are reported" "$(wc -l < "$WORK/report.tsv")" "2"
check "thirteen in kolonie-platform" "$(grep platform "$WORK/report.tsv" | cut -f2)" "13"
check "six in kolonie-infra" "$(grep 'infra' "$WORK/report.tsv" | cut -f2)" "6"

echo "== 5. a success anywhere in the list ends the streak"
# Not `count of failures` — `count of failures before the first success`. A run
# of 1 failure, 1 success, 9 failures is a pipeline that recovered.
runs failure success failure failure failure failure > "$FIX/platform.json"
runs success                                          > "$FIX/infra.json"
check "exit 0" "$(run_check)" "0"

echo "== 6. cancelled breaks the streak without extending it"
# Somebody cancelling a superseded deploy is not a failing pipeline. It must not
# count as a failure, and it must not read as a recovery either — so a streak
# interrupted by one is under threshold rather than over it.
runs failure cancelled failure failure > "$FIX/platform.json"
runs success                           > "$FIX/infra.json"
check "exit 0" "$(run_check)" "0"

echo "== 7. a run still in progress is not evidence in either direction"
# `conclusion: null`. Counting it as a failure would file on an outage that has
# not happened; counting it as a success would end one that is still running.
printf '{"workflow_runs":[{"conclusion":null,"html_url":"https://example.invalid/run/x","created_at":"2026-08-10T09:00:00Z","display_title":"in flight"},{"conclusion":"failure","html_url":"https://example.invalid/run/0","created_at":"2026-08-10T08:00:00Z","display_title":"a"},{"conclusion":"failure","html_url":"https://example.invalid/run/1","created_at":"2026-08-10T07:00:00Z","display_title":"b"}]}\n' \
  > "$FIX/platform.json"
runs success > "$FIX/infra.json"
check "exit 1 — the two completed failures still count" "$(run_check)" "1"
check "and the in-flight run is not one of them" "$(grep platform "$WORK/report.tsv" | cut -f2)" "2"

echo "== 8. an API that will not answer is partial, not green"
# The dangerous direction. An unreadable answer must never read as *no failures*,
# because that is the alarm silently switching itself off.
printf '{"message":"API rate limit exceeded"}\n' > "$FIX/platform.json"
runs success success > "$FIX/infra.json"
rc=$(run_check)
check "it does not file on an unreachable API" "$rc" "0"
contains "$(cat "$WORK/err")" "partial" "but it says the answer is partial"
contains "$(cat "$WORK/report.tsv")" "unreadable" "and the report records which"

echo "== 9. it asks for completed runs on main, and both workflows"
runs success > "$FIX/platform.json"
runs success > "$FIX/infra.json"
run_check >/dev/null
contains "$(cat "$CURL_LOG")" "branch=main" "asked for main"
contains "$(cat "$CURL_LOG")" "status=completed" "asked for completed runs only"
contains "$(cat "$CURL_LOG")" "build-and-deploy.yml" "asked kolonie-platform"
contains "$(cat "$CURL_LOG")" "deploy.yml" "asked kolonie-infra"

echo "== 10. the threshold is a setting, and the default is two"
runs failure success > "$FIX/platform.json"
runs success         > "$FIX/infra.json"
check "one failure at a threshold of one is the alarm" \
  "$(CONSECUTIVE_FAILURES=1 bash "$SCRIPT" check "$WORK/report.tsv" 2>/dev/null; echo $?)" "1"
check "and at the default it is not" "$(run_check)" "0"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
