#!/bin/bash
# Rehearse backup.sh without a VPS, a database, or an object store.
#
# Usage: ./scripts/rehearse-backup.sh
#
# Same idea as rehearse-deploy.sh, for a script with the same shape of problem:
# every interesting branch of `backup.sh` is a *failure* branch, and failure
# branches in a backup are discovered years later, by the person restoring.
#
# The one that matters most is case 3. A dump truncated by a killed container is
# still a file, `pg_dump` does not always exit non-zero when it happens, and a
# snapshot made from it restores cleanly right up to the point where the SQL
# stops. Every case below exists because getting it wrong produces a backup that
# looks fine until it is needed.
#
# Add a case here for every branch that decides whether a snapshot is written.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$BIN" "$WORK/backups"
cp -r "$ROOT/scripts" "$WORK/"

# Fake credentials, so that the script's own configuration check is exercised
# rather than bypassed. Nothing here reaches a network.
cat > "$WORK/backup.env" <<'ENV'
RESTIC_REPOSITORY=s3:example.invalid/rehearsal
RESTIC_PASSWORD=rehearsal
AWS_ACCESS_KEY_ID=rehearsal
AWS_SECRET_ACCESS_KEY=rehearsal
ENV

# --- the stubs ------------------------------------------------------------
# Between them they answer every question backup.sh asks of the outside world.
# The switches (PG_DOWN, FAIL_DUMP, TRUNCATED, EMPTY, HUGE_DB, FAIL_RESTIC,
# NO_SNAPSHOT, FAIL_CHECK) are how a case chooses its branch.

cat > "$BIN/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$CALL_LOG"

case "$1" in
  info) exit 0 ;;
  inspect)
      # "is the postgres container running"
      [ "${PG_DOWN:-}" = 1 ] && { echo "false"; exit 0; }
      echo "true"; exit 0 ;;
  exec)
      # Find the program being run inside the container: skip `exec`, any flags,
      # and the container name.
      shift
      while [ $# -gt 0 ]; do
        case "$1" in -*) shift ;; *) break ;; esac
      done
      container="$1"; shift
      prog="$1"

      case "$prog" in
        psql)
            # The psql being restored *into* is the one reading stdin. Record how
            # many bytes actually arrived: that count is the only way to tell a
            # restore from a no-op, and a no-op is exactly what a closed stdin
            # produces — silently, with a zero exit status.
            if printf '%s' "$*" | grep -q 'ON_ERROR_STOP'; then
                wc -c > "$CALL_LOG.restored-bytes"
                exit 0
            fi
            case "$*" in
              *pg_database_size*)
                  if [ "${HUGE_DB:-}" = 1 ]; then echo "999999999999"; else echo "10485760"; fi ;;
              *pg_stat_user_tables*)
                  # The live and the restored database agree, unless a case asks
                  # them not to. They are told apart by the database name: the
                  # throwaway one is `restoretest_<timestamp>`.
                  echo "citizens|3"
                  if [ "${ROWS_DIFFER:-}" = 1 ] && printf '%s' "$*" | grep -q 'restoretest_'; then
                      echo "tasks|1"
                  else
                      echo "tasks|7"
                  fi ;;
            esac
            exit 0 ;;
        pg_dump)
            [ "${FAIL_DUMP:-}" = 1 ] && { echo "pg_dump: error: connection failed" >&2; exit 1; }
            [ "${EMPTY:-}" = 1 ] && exit 0
            echo "-- PostgreSQL database dump"
            echo "CREATE TABLE citizens (id int);"
            # Pad past the 1 KB floor so that the size check is not what is
            # being tested here — the trailer is.
            head -c 2000 /dev/zero | tr '\0' '-'
            echo
            if [ "${TRUNCATED:-}" != 1 ]; then
              echo "--"
              echo "-- PostgreSQL database dump complete"
              echo "--"
            fi
            exit 0 ;;
      esac
      exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

cat > "$BIN/restic" <<'STUB'
#!/bin/bash
echo "restic $*" >> "$CALL_LOG"

case "$1" in
  backup)
      [ "${FAIL_RESTIC:-}" = 1 ] && { echo "Fatal: unable to open repository" >&2; exit 1; }
      exit 0 ;;
  snapshots)
      [ "${NO_SNAPSHOT:-}" = 1 ] && { echo "[]"; exit 0; }
      echo '[{"time":"2026-07-30T03:00:00Z","short_id":"a1b2c3d4","id":"a1b2c3d4e5f6"}]'
      exit 0 ;;
  check)
      [ "${FAIL_CHECK:-}" = 1 ] && { echo "Fatal: pack file is missing" >&2; exit 1; }
      exit 0 ;;
  dump)
      # Enough SQL that "did anything arrive" is answerable by counting bytes.
      echo "-- PostgreSQL database dump"
      echo "CREATE TABLE citizens (id int);"
      echo "-- PostgreSQL database dump complete"
      exit 0 ;;
  unlock) exit 0 ;;
  cat) exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/restic"

# `env "$@"` rather than `"$@" bash …`, and the difference is not cosmetic.
#
# A shell decides at *parse* time which leading words of a command are variable
# assignments. A word that only looks like one after expansion is not an
# assignment — it is the command name. So `SWITCH=1 bash script` written as
# `"$@" bash script` does not set SWITCH: it tries to execute a program called
# `SWITCH=1`, fails with 127, and never runs the script at all.
#
# Every case that asserts only "exits non-zero" would then pass on the 127 and
# prove nothing. That is how this was found — the message assertions failed
# while the exit-code assertions passed, in exactly the cases that used a
# switch. `env` takes the assignments as arguments, so expansion is fine.
run_backup() {
  rm -f "$WORK/call.log"
  env CALL_LOG="$WORK/call.log" \
  PATH="$BIN:$PATH" \
  KOLONIE_DEPLOY_DIR="$WORK" KOLONIE_BACKUP_DIR="$WORK/backups" \
  KOLONIE_BACKUP_ENV="$WORK/backup.env" BACKUP_LOCK_WAIT=1 \
  "$@" bash "$WORK/scripts/backup.sh" backup 2>&1
}

run_restore_test() {
  rm -f "$WORK/call.log" "$WORK/call.log.restored-bytes"
  env CALL_LOG="$WORK/call.log" \
  PATH="$BIN:$PATH" \
  KOLONIE_DEPLOY_DIR="$WORK" KOLONIE_BACKUP_DIR="$WORK/backups" \
  KOLONIE_BACKUP_ENV="$WORK/backup.env" \
  "$@" bash "$WORK/scripts/backup.sh" restore-test 2>&1
}

calls() { cat "$WORK/call.log" 2>/dev/null; }
restored_bytes() { cat "$WORK/call.log.restored-bytes" 2>/dev/null | tr -d ' ' || echo 0; }

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fi; [ "$2" = "$3" ] || fail=$((fail+1)); }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

# --- 1: the happy path ----------------------------------------------------
echo "1. a complete dump is backed up, verified and cleaned up"
rm -f "$WORK/backups/.last-success"
out=$(run_backup); rc=$?
check "exits 0" "$rc" "0"
contains "$out" "snapshot a1b2c3d4" "reports the snapshot the repository confirmed"
contains "$(calls)" "restic backup" "restic was asked to back up"
contains "$(calls)" "$WORK/backups/kolonie.sql" "the dump path was handed to restic"
contains "$(calls)" "restic check" "the repository was checked afterwards"
# A stale lock left by a killed run blocks every later backup permanently, so
# clearing one is part of a normal run and not a manual repair step.
check "stale locks are cleared before the backup" \
  "$(grep -n 'restic unlock\|restic backup' "$WORK/call.log" | head -1 | grep -c unlock)" "1"
check "the dump is not left on disk" "$([ -f "$WORK/backups/kolonie.sql" ] && echo yes || echo no)" "no"
check "a success timestamp was written" "$([ -f "$WORK/backups/.last-success" ] && echo yes || echo no)" "yes"

# --- 2: pg_dump fails -----------------------------------------------------
echo "2. a failed pg_dump never reaches the repository"
out=$(run_backup FAIL_DUMP=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
absent "$(calls)" "restic backup" "no snapshot was attempted"

# --- 3: a truncated dump --------------------------------------------------
# The case this whole script exists for. pg_dump "succeeded", the file is
# plausible, and the SQL simply stops. Nothing downstream would notice.
echo "3. a truncated dump is refused"
out=$(run_backup TRUNCATED=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "truncated" "says why"
absent "$(calls)" "restic backup" "no snapshot was attempted"
check "the bad dump is not left behind" "$([ -f "$WORK/backups/kolonie.sql" ] && echo yes || echo no)" "no"

# --- 4: an empty dump -----------------------------------------------------
echo "4. an empty dump is refused"
out=$(run_backup EMPTY=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
absent "$(calls)" "restic backup" "no snapshot was attempted"

# --- 5: the database is not running ---------------------------------------
echo "5. a stopped database is not silently backed up as nothing"
out=$(run_backup PG_DOWN=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
absent "$(calls)" "pg_dump" "no dump was attempted"
absent "$(calls)" "restic backup" "no snapshot was attempted"

# --- 6: restic itself fails -----------------------------------------------
echo "6. an unreachable repository fails loudly and cleans up"
out=$(run_backup FAIL_RESTIC=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "previous snapshot is still the newest" "says what the state now is"
check "the dump is not left on disk" "$([ -f "$WORK/backups/kolonie.sql" ] && echo yes || echo no)" "no"

# --- 7: the repository does not confirm the snapshot ----------------------
# restic exiting 0 is not the same as the repository holding a snapshot.
echo "7. a backup the repository cannot confirm is a failure"
out=$(run_backup NO_SNAPSHOT=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "no snapshot" "says the repository disagreed"

# --- 8: the repository does not check out ---------------------------------
echo "8. a snapshot into a broken repository is a failure"
out=$(run_backup FAIL_CHECK=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "does not check out" "says what failed"

# --- 9: the previous success timestamp survives a failure -----------------
# health-report.sh reads this file to decide whether backups have stopped. A
# failing run that refreshed it would report the stack as healthy for as long as
# the failures kept coming — the exact opposite of what it is for.
echo "9. a failed run does not refresh the success timestamp"
echo "2020-01-01T00:00:00+00:00" > "$WORK/backups/.last-success"
run_backup FAIL_RESTIC=1 >/dev/null
check "timestamp untouched" "$(cat "$WORK/backups/.last-success")" "2020-01-01T00:00:00+00:00"

# --- 10: missing configuration --------------------------------------------
echo "10. missing credentials stop the run before it touches the database"
mv "$WORK/backup.env" "$WORK/backup.env.off"
out=$(run_backup); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "RESTIC_REPOSITORY" "names the missing setting"
absent "$(calls)" "pg_dump" "the database was never touched"
mv "$WORK/backup.env.off" "$WORK/backup.env"

# --- 11: not enough disk for the dump -------------------------------------
echo "11. too little free space stops the run before the dump"
out=$(run_backup HUGE_DB=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "free for the dump" "says how much was needed"
absent "$(calls)" "pg_dump" "no dump was attempted"

# --- 12: a stuck previous run ---------------------------------------------
# Two backups must not run at once, and a wait that never ends would turn one
# stuck run into a backup that silently stops forever.
echo "12. a held lock is waited for, then reported"
( flock 9; sleep 5 ) 9>>"$WORK/backups/.lock" &
holder=$!
sleep 0.3
out=$(run_backup); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "previous run is stuck" "says why it gave up"
absent "$(calls)" "restic backup" "no concurrent snapshot"
wait "$holder" 2>/dev/null

# --- 13: the restore test actually delivers SQL ---------------------------
# The case that exists because the first real restore test failed for this
# reason. The helper that runs docker closes stdin — correct for every other
# call, fatal for this one: psql reads EOF, does nothing, exits 0, and `restic
# dump` dies on SIGPIPE. The restore then reports an error whose stated cause
# ("restore failed") is not the actual one ("no SQL was ever delivered").
#
# Asserting on the exit status alone would not have caught it either way round.
# The byte count is the assertion that means something.
echo "13. the restore test streams the dump into psql"
out=$(run_restore_test); rc=$?
check "exits 0" "$rc" "0"
check "SQL reached psql" "$([ "$(restored_bytes)" -gt 0 ] && echo yes || echo no)" "yes"
contains "$(calls)" "CREATE DATABASE restoretest_" "restored into a throwaway database"
contains "$(calls)" "DROP DATABASE IF EXISTS restoretest_" "dropped it again"
contains "$out" "identical: 2 tables, 10 rows" "compared the row counts"

# --- 14: a restore that comes back wrong ----------------------------------
echo "14. a row-count mismatch is reported, not passed over"
out=$(run_restore_test ROWS_DIFFER=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "The two databases differ" "says so"
contains "$(calls)" "DROP DATABASE IF EXISTS restoretest_" "still dropped the throwaway database"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
