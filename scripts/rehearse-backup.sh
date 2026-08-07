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

# The compose secrets file, which since #45 is part of the snapshot. Nineteen
# assignments, the number the host carried on 2026-07-31, so that the floor is
# cleared the way the real file clears it.
#
# CANARY is what case 20 looks for. Every value here is invented, and the point
# of that case is that none of them can reach a log line, a message or the
# rehearsal's own output — a backup script is precisely where someone eventually
# adds an echo to debug a failing run.
CANARY='rehearsal-canary-must-never-be-printed'
write_env() {
  {
    echo "POSTGRES_USER=kolonie"
    echo "POSTGRES_PASSWORD=$CANARY"
    for n in $(seq 1 17); do echo "REHEARSAL_VAR_$n=$CANARY"; done
  } > "$WORK/.env"
}
write_env

# Neighbours of the real file on the host. They must not be swept into the
# snapshot: restic backs up the paths it is handed, and these are not among them.
echo "POSTGRES_PASSWORD=$CANARY" > "$WORK/.env.bak-20260729-213912"
echo "POSTGRES_PASSWORD=$CANARY" > "$WORK/.env.example"

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
      # `--latest N` is per (host, paths) group, not per repository. Once the
      # repository holds two shapes of snapshot — one path before #45, two after
      # — it answers with one of each, oldest group first, and a `head -1` takes
      # the stale one. That is exactly what happened on the host on 2026-07-31.
      #
      # The stub used to return a single element whatever it was asked, which is
      # what let the bug ship: it modelled the repository as it was rather than as
      # it would be. `snapshots latest` is the query that means "newest in this
      # repository", and this stub is now the thing that tells the two apart.
      if printf '%s' "$*" | grep -q -- '--latest'; then
          echo '[{"time":"2026-07-31T03:00:00Z","short_id":"0ldgr0up","id":"0ldgr0upaaaa"},'\
'{"time":"2026-07-31T11:35:00Z","short_id":"a1b2c3d4","id":"a1b2c3d4e5f6"}]'
          exit 0
      fi
      echo '[{"time":"2026-07-31T11:35:00Z","short_id":"a1b2c3d4","id":"a1b2c3d4e5f6"}]'
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
  ls)
      # What the snapshot holds, which backup.sh reads back rather than trusting
      # the exit code of the write. NO_ENV_IN_SNAPSHOT is a snapshot that was
      # written without the secrets file — the failure the read-back exists for.
      #
      # `0ldgr0up` is the pre-#45 shape: a real snapshot, correctly stored, with
      # only the dump in it. A run that identifies the wrong snapshot therefore
      # fails here rather than passing on a listing that was never checked — the
      # same way it failed on the host.
      #
      # The trap is #92, and it is what makes this stub able to fail the old
      # code. Real `restic ls` is a Go program writing over a network; a reader
      # that stops early leaves it writing into a closed pipe, and it takes
      # SIGPIPE often enough to matter — 5 runs in 30 on the host. A shell stub
      # is far too fast to lose that race on its own, so the noise below forces
      # it: more than a pipe buffer of output *after* the line the old reader
      # matched on, which any short-circuiting reader is guaranteed to abandon.
      trap 'echo "restic ls TOOK SIGPIPE" >> "${CALL_LOG:-/dev/null}"; exit 141' PIPE
      # An `ls` that fails outright, which is a different fact from a snapshot
      # missing a path and used to be indistinguishable from one.
      [ "${FAIL_LS:-}" = 1 ] && { echo "Fatal: repository is already locked" >&2; exit 1; }
      echo "${KOLONIE_BACKUP_DIR:-/var/backups/kolonie}/kolonie.sql"
      [ "$2" = "0ldgr0up" ] && exit 0
      [ "${NO_ENV_IN_SNAPSHOT:-}" = 1 ] || echo "${KOLONIE_DEPLOY_DIR:-/opt/kolonie}/.env"
      # The credential files (kolonie-platform#105). NO_SECRETS_IN_SNAPSHOT is a
      # snapshot written without them — invisible until a restore, which is why
      # backup.sh reads the listing back instead of trusting the write's exit code.
      if [ "${NO_SECRETS_IN_SNAPSHOT:-}" != 1 ] && [ -d "${KOLONIE_SECRETS_DIR:-${KOLONIE_DEPLOY_DIR:-/opt/kolonie}/secrets}" ]; then
        find "${KOLONIE_SECRETS_DIR:-${KOLONIE_DEPLOY_DIR:-/opt/kolonie}/secrets}" -type f 2>/dev/null
      fi
      # 128 KiB of paths that match nothing, written after every line the checks
      # look for. A reader that consumes the listing takes all of it and this
      # costs a few milliseconds; a reader that stopped at its match is long gone
      # and the write above lands in a closed pipe. Off by default, because every
      # other case in this file runs `ls` too.
      if [ "${LS_TRAILING_NOISE:-}" = 1 ]; then
        i=0; while [ "$i" -lt 4096 ]; do
          echo "/var/backups/kolonie/padding-that-matches-no-check-$i"
          i=$((i+1))
        done
      fi
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

# --- 15: the secrets file rides along -------------------------------------
# #45. The database alone is not a recoverable colony: BAN_MARK_SALT lives in
# /opt/kolonie/.env and the ban marks it salted live in the dump, so a snapshot
# holding one without the other restores rows that can never match again.
echo "15. the secrets file is in the same snapshot as the dump"
write_env
out=$(run_backup); rc=$?
check "exits 0" "$rc" "0"
contains "$(calls)" "$WORK/.env" "the secrets file was handed to restic"
contains "$(calls)" "--tag kolonie-env" "the snapshot is tagged as carrying it"
contains "$(calls)" "--tag kolonie-db" "the original tag is still there"
check "one snapshot, not two" "$(grep -c 'restic backup' "$WORK/call.log")" "1"
absent "$(calls)" ".env.bak-" "the .env.bak-* neighbours were not swept in"
absent "$(calls)" ".env.example" "nor .env.example"

# --- 16: a missing secrets file -------------------------------------------
# Deliberately fatal to the whole run rather than to its second half. A snapshot
# that looks complete and is not is found by the person restoring it, and by
# then there is nothing left to check it against.
echo "16. a missing secrets file stops the run before the database is touched"
echo "2020-01-01T00:00:00+00:00" > "$WORK/backups/.last-success"
rm -f "$WORK/.env"
out=$(run_backup); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "does not exist" "says what is missing"
absent "$(calls)" "pg_dump" "no dump was attempted"
absent "$(calls)" "restic backup" "no snapshot was attempted"
check "the success timestamp survives" "$(cat "$WORK/backups/.last-success")" "2020-01-01T00:00:00+00:00"
write_env

# --- 17: an emptied secrets file ------------------------------------------
# The .env equivalent of the truncated dump in case 3, and the likelier accident
# of the two: a redirection that clobbers the file before it writes it.
echo "17. an empty secrets file is refused"
: > "$WORK/.env"
out=$(run_backup); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "is empty" "says why"
absent "$(calls)" "restic backup" "no snapshot was attempted"
write_env

# --- 18: a half-written secrets file --------------------------------------
# Not empty, not obviously wrong, and worthless. Nothing downstream of the
# snapshot would notice: the file parses, it just no longer holds the colony.
echo "18. a secrets file below the assignment floor is refused"
printf 'POSTGRES_USER=kolonie\nNODE_ENV=production\n' > "$WORK/.env"
out=$(run_backup); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "looks truncated" "says what it suspects"
contains "$out" "2 assignments" "says how many it counted"
absent "$(calls)" "restic backup" "no snapshot was attempted"
write_env

# --- 19: the snapshot came back without it --------------------------------
# restic exiting 0 is not the same as the snapshot holding both paths — the same
# distinction case 7 draws for the snapshot existing at all.
echo "19. a snapshot that does not contain the secrets file is a failure"
echo "2020-01-01T00:00:00+00:00" > "$WORK/backups/.last-success"
out=$(run_backup NO_ENV_IN_SNAPSHOT=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "does not contain" "says what is missing from it"
check "the success timestamp survives" "$(cat "$WORK/backups/.last-success")" "2020-01-01T00:00:00+00:00"

# --- 20: no secret is ever printed ----------------------------------------
# AGENTS.md §11. This script now reads a file where every line is a production
# secret, and the pressure to echo one while debugging a failing run is highest
# in exactly the branches above. Counting is allowed; printing is not.
echo "20. no value from the secrets file reaches the output"
all=""
write_env;                                   all+=$(run_backup)$'\n'
all+=$(run_backup NO_ENV_IN_SNAPSHOT=1)$'\n'
all+=$(run_backup FAIL_RESTIC=1)$'\n'
printf 'POSTGRES_USER=kolonie\n' > "$WORK/.env"
all+=$(run_backup)$'\n'
: > "$WORK/.env"
all+=$(run_backup)$'\n'
write_env
absent "$all" "$CANARY" "no secret value in any of five runs"
contains "$all" "env: 19 assignments" "the count is what gets reported instead"

# --- 21: the newest snapshot, across path groups --------------------------
# The defect #45 shipped and the read-back caught, four minutes later, on the
# host. `restic snapshots --latest 1` groups by (host, paths), so a repository
# holding both the old one-path shape and the new two-path shape answers with one
# of each — and the old one comes first. The run then verified this morning's
# snapshot, correctly found no .env in it, and refused.
#
# The assertion is on *which* snapshot the run names, because the failure is not
# that a check went wrong: both the check and the snapshot were fine. It looked
# at the wrong object.
echo "21. the snapshot that is verified is the newest one in the repository"
write_env
out=$(run_backup); rc=$?
check "exits 0" "$rc" "0"
contains "$out" "snapshot a1b2c3d4" "named the newest snapshot"
absent "$out" "0ldgr0up" "not the newest of the old path group"
contains "$(calls)" "restic snapshots latest" "asked for the repository's newest, not a per-group latest"
absent "$(calls)" "snapshots --host kolonie --latest" "did not group by path"

echo "== 20. the credential files go into the same snapshot (kolonie-platform#105)"
# `.env` stopped being the whole of this host's secrets on 2026-08-01: the
# Traefik htpasswd (#30) and the GitHub App's private key (#55) are files,
# because neither fits in a `.env`. A restore without them brings back a host
# that looks whole and has silently lost two capabilities — both degrade rather
# than crash by design, so nothing would say so.
mkdir -p "$WORK/secrets"
printf 'gregor:$2y$05$notarealhash\n' > "$WORK/secrets/pgadmin.htpasswd"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nnot-a-real-key\n-----END RSA PRIVATE KEY-----\n' > "$WORK/secrets/kolonie-triage-app.pem"
out=$(run_backup)
check "the run succeeded" "$?" "0"
contains "$out" "secrets: 2 file(s)" "counted them in preflight"
contains "$out" "and 2 secret file(s)" "and said what it was sending"
contains "$(calls)" "$WORK/secrets" "the directory is one of the paths"
contains "$(calls)" "--tag kolonie-secrets" "tagged, so 'which snapshots have them' is one query"

echo "== 20b. and their absence from the snapshot is caught, not assumed"
# The same read-back `.env` has. `restic backup` exiting 0 says the command
# worked, not that the paths are in the snapshot.
out=$(run_backup NO_SECRETS_IN_SNAPSHOT=1)
check "the run failed" "$?" "1"
contains "$out" "does not contain $WORK/secrets" "named what was missing"
contains "$out" "the App key and the htpasswd are not backed up" "and what that costs"

echo "== 20c. a host with no secrets directory still backs up"
# The half that must not become a check firing on a correct configuration. A
# host with neither pgAdmin nor the App has no such directory, and the database
# backup is not its hostage.
rm -rf "$WORK/secrets"
out=$(run_backup)
check "the run succeeded" "$?" "0"
contains "$out" "does not exist — nothing to include" "said so once"
absent "$(calls)" "--tag kolonie-secrets" "and did not tag a snapshot that has none"
contains "$out" "ok" "the backup completed"

echo "== 20d. an empty secrets directory is the same case"
mkdir -p "$WORK/secrets"
out=$(run_backup)
check "the run succeeded" "$?" "0"
contains "$out" "is empty — nothing to include" "said so"
absent "$(calls)" "--tag kolonie-secrets" "no tag"
rm -rf "$WORK/secrets"

echo "== 22. the listing is read to the end, not until the first match (#92)"
# The night of 2026-08-07, and the worst shape a check can have: it failed on a
# correct backup, it failed at random so it read as a real intermittent fault,
# and it aborted before `.last-success` was written — so a repository holding a
# good snapshot reported itself stale for a day.
#
# The mechanism is this script's own `pipefail` meeting `grep -q`. `grep -q`
# exits at its match — `.env` is the third of twelve lines — `restic ls` is left
# writing into a closed pipe, and a SIGPIPE there becomes the pipeline's status.
# Measured on the host: 5 failures in 30 runs piped, 0 in 30 captured first.
#
# The assertion is on the stub taking SIGPIPE rather than on the exit code alone,
# because an exit code cannot tell the two apart: the old code passed most of the
# time, and a case that passes four times in five proves nothing about the fifth.
echo "22. a listing longer than the pipe buffer does not fail the verification"
write_env
# Reset to the sentinel first, or the timestamp assertion below passes on the
# previous case's success and proves nothing about this one.
echo "2020-01-01T00:00:00+00:00" > "$WORK/backups/.last-success"
out=$(run_backup LS_TRAILING_NOISE=1); rc=$?
check "exits 0" "$rc" "0"
contains "$out" "ok" "the backup completed"
absent "$(calls)" "restic ls TOOK SIGPIPE" "nothing closed the pipe on restic ls"
check "a success timestamp was written" \
  "$([ "$(cat "$WORK/backups/.last-success")" != "2020-01-01T00:00:00+00:00" ] && echo yes || echo no)" "yes"

echo "== 22b. and a genuinely missing path is still caught, noise or not"
# The half that must not be lost in fixing the other one. Reading the listing to
# the end is not the same as not reading it.
out=$(run_backup LS_TRAILING_NOISE=1 NO_ENV_IN_SNAPSHOT=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "does not contain" "still says what is missing from it"

echo "== 22c. a failing 'restic ls' says that, rather than blaming the snapshot"
# The other half of what `2>/dev/null` cost. An unreachable repository, a stale
# lock and a corrupt index all arrived as *the secrets are not backed up*, which
# sends the reader to the wrong half of the system entirely.
out=$(run_backup FAIL_LS=1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
contains "$out" "could not be verified" "names the command that failed"
absent "$out" "the secrets are not backed up" "does not report a missing file it never looked for"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
