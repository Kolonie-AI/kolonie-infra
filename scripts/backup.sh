#!/bin/bash
# Kolonie AI — the database backup (#4)
#
# Usage:
#   ./scripts/backup.sh                run a backup
#   ./scripts/backup.sh verify         show the repository and its newest snapshot
#   ./scripts/backup.sh restore-test   restore into a throwaway database and compare
#
# Dumps Postgres and stores the dump in a restic repository on an S3-compatible
# object store. Normally invoked by `kolonie-backup.timer`, daily.
#
# ## Why this runs on the host and not as a compose service
#
# A backup that runs inside the stack shares the fate of the stack. Every
# scenario in `docs/disaster-recovery.md` that needs a backup is a scenario in
# which compose is broken, torn down, or half-deployed — the deploy that failed,
# the corrupted volume, the compromised host. A container in `docker-compose.yml`
# would be down in exactly those moments. A systemd timer on the host is not.
#
# It also keeps `pg_dump` at the server's own version. `pg_dump` refuses to dump
# a server newer than itself, so a backup image would have to be rebuilt in step
# with every Postgres upgrade — and when someone forgets, the backup stops and
# says so only in a log nobody reads. `docker exec` into the running container
# always uses the matching binary, including after an upgrade nobody told this
# script about.
#
# ## Why the dump is written to a file before restic sees it
#
# The obvious form is `pg_dump | restic backup --stdin`, and it is wrong. restic
# reads that pipe until EOF and commits whatever arrived. If `pg_dump` dies at
# 60% — disk full, container killed mid-dump, connection dropped — restic sees a
# clean EOF, writes a snapshot from the truncated SQL, and that snapshot becomes
# `latest`. `${PIPESTATUS[0]}` can tell us afterwards that it failed, but by then
# the bad snapshot exists and it is the one a restore under pressure reaches for.
#
# A truncated dump is worse than no dump, because it is only discovered halfway
# through a restore. So: dump to a file, prove the file is a complete dump, and
# only then let restic near it. Nothing enters the repository that has not been
# checked.
#
# ## Why the dump is not compressed before restic
#
# restic splits the file into content-defined chunks and stores only the chunks
# it has not seen. Two consecutive dumps of the same database differ in very
# little, so day two costs the difference rather than the whole file. Compress
# first — `gzip`, or `pg_dump -Fc` — and every byte changes, deduplication drops
# to nothing, and each day costs a full copy. restic compresses the chunks
# itself, after deduplication, which is the order that works.
#
# This is what makes "keep every snapshot" affordable, and keeping every snapshot
# is the current policy: no `restic forget` runs anywhere. See
# `docs/disaster-recovery.md` for the one line that changes that.
#
# ## Why the secrets file is in the snapshot too (#45)
#
# `/opt/kolonie/.env` is backed up alongside the dump. This reverses what
# `docs/disaster-recovery.md` argued until 2026-07-31 — that secrets must not go
# where the database goes — and the reversal is deliberate.
#
# The separation bought less than it read like. `backup.env` is root-only, so
# anyone who can read the object-store credentials is already root on this host,
# and root can read `/opt/kolonie/.env` directly. The only scenario the split
# defended against was the object-store key *and* the repository password leaking
# with no host access at all — and an attacker in that position already holds
# every user record in the database.
#
# Against that stood a hole: part of the backup was conditional on a secret that
# was not in it. `BAN_MARK_SALT` salts the ban marks stored *in the database*, and
# `packages/db/src/ban-salt.ts` states that every existing mark stops matching the
# day that value moves. Restore the database without it and the rows come back
# permanently unmatchable. That is not a gap in the rebuild, it is a gap in the
# backup.
#
# The retention policy makes it nearly free and adds something worth having:
# nothing prunes, so a daily snapshot of this file is a version history of it.
# `restic diff` shows the day a secret changed, and a clobbered file is
# recoverable from yesterday.
#
# **What stays out is `backup.env` itself.** It holds the repository URL, its
# password and the object-store credentials — backing it up inside the repository
# it unlocks is circular and worthless during a restore. It belongs in the
# maintainer's password manager, and that is where it is. The rule that falls out:
# everything the host needs to come back goes into restic; what unlocks restic
# goes into the vault.
#
# ## Configuration
#
# Read from the environment, and from `/opt/kolonie/backup.env` if that file
# exists. It holds the object-store credentials and the restic password, is
# root-only, and is deliberately *not* the compose `.env`: the deploy pulls that
# one into the checkout, which is how #27 put every production secret in
# cleartext into a directory that did not need them. The stack does not need the
# backup credentials, so it does not get them.
#
#   RESTIC_REPOSITORY       restic repository URL
#   RESTIC_PASSWORD_FILE    file holding the repository password
#   AWS_ACCESS_KEY_ID       object-store key id
#   AWS_SECRET_ACCESS_KEY   object-store application key
#
# No value of any of these appears in this file, in the units, or in any log line
# it writes — AGENTS.md §11.

set -uo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
BACKUP_ENV="${KOLONIE_BACKUP_ENV:-$DEPLOY_DIR/backup.env}"

# Not $DEPLOY_DIR/backups, for two reasons that both bite.
#
# That directory already belongs to deploy.sh, which fills it with `ps_*.json`
# container-state snapshots — a second, unrelated meaning of the word "backup"
# in one directory is how someone eventually deletes the wrong thing. And
# /opt/kolonie is a git checkout that the deploy resets with `git reset --hard
# origin/main`; nothing whose loss matters should live inside a directory whose
# contents are decided by a remote branch.
#
# /var/backups is where Debian and Ubuntu already put exactly this, so a person
# looking for backups on an unfamiliar host looks here first.
WORK_DIR="${KOLONIE_BACKUP_DIR:-/var/backups/kolonie}"
LOCK_FILE="$WORK_DIR/.lock"

PG_CONTAINER="${POSTGRES_CONTAINER:-kolonie-postgres}"

# restic records the machine's hostname in every snapshot. That name would then
# live at a third party, in metadata we do not control the retention of, for no
# operational gain — the repository holds one host's backups. A fixed logical
# name keeps the snapshot list readable and the host out of it (AGENTS.md §11).
RESTIC_HOST_LABEL="kolonie"

# The path the dump occupies inside a snapshot. Stable on purpose: it is what
# every restore command in docs/disaster-recovery.md names.
DUMP_NAME="kolonie.sql"

# The compose secrets file, backed up in place rather than copied into WORK_DIR.
#
# In place, because the path inside the snapshot is then the path it has to be
# restored to — a restore under pressure should not have to know where the file
# used to live. Naming it explicitly also means the `.env.bak-*` files that
# accumulate next to it are not swept along: restic backs up the paths it is
# given, and this is the only one it is given.
ENV_FILE="${KOLONIE_ENV_FILE:-$DEPLOY_DIR/.env}"

# The floor below which the secrets file is assumed damaged rather than small.
#
# The same argument as the 1 KB floor on the dump: a file that has been truncated
# or half-written is still a file, and a snapshot made from it is discovered at
# restore time, by someone who has no way left to check. There were 19
# assignments on 2026-07-31; ten is low enough that a legitimate consolidation
# does not trip it and high enough that a clobbered file does.
#
# It counts assignments and never reads a value. No part of this script may put
# the contents of this file into a variable, a log line or a message — the
# no-secrets rule is AGENTS.md §11, and a backup script is exactly the place
# where "just print it to debug" is tempting.
ENV_MIN_ASSIGNMENTS="${KOLONIE_ENV_MIN_ASSIGNMENTS:-10}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

# --- configuration --------------------------------------------------------

# Sourced rather than exported by the caller so that a hand-run works the same
# way the timer does. `set -a` exports what the file defines; restic and the AWS
# SDK read their credentials from the environment, not from arguments, which is
# also what keeps them off the process list.
if [ -f "$BACKUP_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$BACKUP_ENV"
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-kolonie}"
POSTGRES_DB="${POSTGRES_DB:-kolonie}"

require_config() {
    [ -n "${RESTIC_REPOSITORY:-}" ] || die "RESTIC_REPOSITORY is not set (expected it in $BACKUP_ENV)"
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] || die "AWS_ACCESS_KEY_ID is not set (expected it in $BACKUP_ENV)"
    [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "AWS_SECRET_ACCESS_KEY is not set (expected it in $BACKUP_ENV)"

    if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
        [ -r "$RESTIC_PASSWORD_FILE" ] || die "RESTIC_PASSWORD_FILE is set but not readable"
    elif [ -z "${RESTIC_PASSWORD:-}" ]; then
        die "neither RESTIC_PASSWORD_FILE nor RESTIC_PASSWORD is set"
    fi

    command -v restic >/dev/null 2>&1 || die "restic is not installed — see docs/disaster-recovery.md"
}

docker_cmd() {
    # Same reasoning as health-report.sh: the timer runs this as root, a human
    # may not be in the docker group. `</dev/null` so the docker CLI cannot eat
    # the stdin of a caller that is piping into this script.
    if docker info >/dev/null 2>&1; then
        docker "$@" </dev/null
    else
        sudo -n docker "$@" </dev/null
    fi
}

# The same, for the one call that is *supposed* to read stdin.
#
# `docker_cmd` closes stdin, and that is right for every call but one. Used for
# the restore, it produces a failure that is both silent and misleading: psql
# reads EOF immediately and exits 0 having done nothing, `restic dump` then
# writes into a closed pipe, takes SIGPIPE, and the pipeline fails with 141 —
# so the restore reports an error while the thing that actually happened is that
# no SQL was ever delivered. Found exactly that way on the first restore test.
docker_pipe() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
    else
        sudo -n docker "$@"
    fi
}

# --- preflight ------------------------------------------------------------

# Is the secrets file whole enough to be worth a snapshot.
#
# Checked in preflight, which means a damaged `.env` stops the database backup
# too. That is the uncomfortable half of the decision and it was taken on
# purpose. The alternative — snapshot the database anyway, warn about the file —
# writes a snapshot that looks complete and is not, and the person who finds out
# is the one restoring it. Every other branch in this script refuses to write
# rather than write something partial, and this one is not the place to start
# making exceptions.
#
# What makes that affordable is that it cannot be silent: the run fails, the unit
# fails, `.last-success` keeps its old timestamp, and health-report.sh turns the
# `backup` row red after 36 hours. And the trigger is almost always an edit made
# seconds earlier by the person now reading the error.
check_env_file() {
    [ -e "$ENV_FILE" ] || die "$ENV_FILE does not exist — refusing to write a snapshot without the secrets (#45)"
    [ -r "$ENV_FILE" ] || die "$ENV_FILE is not readable — run this as root"
    [ -s "$ENV_FILE" ] || die "$ENV_FILE is empty — refusing to overwrite a good history with nothing (#45)"

    # `|| true` because grep -c exits 1 on no matches, and this runs under
    # pipefail inside a command substitution.
    local assignments
    assignments=$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" 2>/dev/null || true)
    assignments=${assignments:-0}

    if [ "$assignments" -lt "$ENV_MIN_ASSIGNMENTS" ]; then
        die "$ENV_FILE holds $assignments assignments, fewer than $ENV_MIN_ASSIGNMENTS — it looks truncated (#45)"
    fi

    echo "env: $assignments assignments" >&2
}

# Everything that can be known before a byte is written is checked here, because
# the alternative is discovering it with a half-finished dump on a full disk.
preflight() {
    docker_cmd inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -q true \
        || die "$PG_CONTAINER is not running — refusing to record a backup that did not happen"

    check_env_file

    mkdir -p -m 755 "$WORK_DIR" || die "cannot create $WORK_DIR"

    # A plain-text dump is normally a good deal smaller than the database on
    # disk — it carries no indexes and no bloat — so twice the database size is
    # a generous floor rather than a tight one. The 50 MB is for the case where
    # the size query fails and the database is tiny anyway.
    local db_bytes need_kb avail_kb
    db_bytes=$(docker_cmd exec "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -tAc "SELECT pg_database_size('$POSTGRES_DB')" 2>/dev/null | tr -dc '0-9')
    need_kb=$(( (${db_bytes:-0} / 1024) * 2 + 51200 ))

    avail_kb=$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $4}')
    [ -n "$avail_kb" ] || die "could not determine free space on $WORK_DIR"

    if [ "$avail_kb" -lt "$need_kb" ]; then
        die "need ~$((need_kb / 1024)) MB free for the dump, have $((avail_kb / 1024)) MB"
    fi
}

# --- the dump -------------------------------------------------------------

# Writes the dump and proves it is complete. Prints the path on stdout; every
# other line this function emits goes to stderr, so the caller can capture one
# without the other.
make_dump() {
    local dump="$WORK_DIR/$DUMP_NAME"
    rm -f "$dump"

    # The dump is the whole database in cleartext, briefly, on a host where the
    # `ubuntu` user does not otherwise have it. The directory stays readable so
    # that health-report.sh can read the success marker without privileges; the
    # dump itself does not. Set here rather than at the top of the script so it
    # covers exactly the redirection below.
    umask 077

    # --format=plain is not the default being restated for clarity; it is a
    # decision. Custom format (-Fc) is compressed, which defeats deduplication
    # (see the header), and it needs pg_restore to read — one more binary that
    # has to exist and match on a host that may be a bare rebuild.
    if ! docker_cmd exec "$PG_CONTAINER" \
            pg_dump --format=plain --no-password -U "$POSTGRES_USER" "$POSTGRES_DB" > "$dump" 2>/dev/null; then
        rm -f "$dump"
        echo "pg_dump failed" >&2
        return 1
    fi

    local size
    size=$(stat -c %s "$dump" 2>/dev/null || echo 0)
    if [ "$size" -lt 1024 ]; then
        rm -f "$dump"
        echo "dump is $size bytes — that is not a database" >&2
        return 1
    fi

    # The trailer is the only *positive* evidence that pg_dump reached the end of
    # its work. A dump cut short by a killed container or a full disk exits
    # non-zero often enough — but not always, and not when the failure is on our
    # side of the pipe. This check costs nothing and closes that gap.
    if ! tail -c 512 "$dump" | grep -q 'PostgreSQL database dump complete'; then
        rm -f "$dump"
        echo "dump has no completion trailer — it is truncated" >&2
        return 1
    fi

    echo "dump: $size bytes" >&2
    echo "$dump"
}

# --- commands -------------------------------------------------------------

# The dump path, at file scope rather than inside do_backup, because the EXIT
# trap that removes it runs after that function has returned — and a `local`
# would be out of scope by then, leaving a cleartext copy of the database on
# disk with nothing scheduled to remove it.
DUMP_PATH=""
cleanup_dump() { [ -n "$DUMP_PATH" ] && rm -f "$DUMP_PATH"; return 0; }

SCRATCH_DB=""
cleanup_scratch() {
    [ -n "$SCRATCH_DB" ] || return 0
    docker_cmd exec "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $SCRATCH_DB" >/dev/null 2>&1
    return 0
}

do_backup() {
    require_config

    # Serialised the way deploy.sh serialises deploys. A second run declining
    # immediately would be wrong — a timer firing while a hand-run is finishing
    # is normal and should queue — but waiting forever would turn one stuck
    # backup into a backup that never runs again and never says so. Five minutes
    # separates the two cases.
    mkdir -p -m 755 "$WORK_DIR" || die "cannot create $WORK_DIR"
    exec 9>>"$LOCK_FILE"
    if ! flock -n 9; then
        log "another backup is running — waiting"
        flock -w "${BACKUP_LOCK_WAIT:-300}" 9 || die "timed out waiting for the backup lock; a previous run is stuck"
    fi

    preflight

    # restic takes its own lock *inside the repository*, and a run killed before
    # it can release that lock leaves it behind — SIGPIPE, an OOM kill, a reboot
    # mid-backup. Every later run then fails, not at the backup but at the check
    # afterwards, with "repository is already locked". It does not heal. Left
    # alone it is a backup that has stopped for good, and the only sign is a unit
    # failing into a journal.
    #
    # This is not hypothetical: it happened on the day this script was written,
    # when a restore test died on SIGPIPE at 10:41 and the next backup failed at
    # 10:45 for a lock four minutes old.
    #
    # `unlock` without `--remove-all` removes only what restic itself judges
    # stale — the creating process is gone, or the lock has aged out — so it
    # cannot cut into a legitimate concurrent operation. The flock above already
    # guarantees no second run of *this* script is in flight.
    restic unlock --quiet 2>/dev/null || true

    DUMP_PATH=$(make_dump) || die "no usable dump was produced — nothing was sent to the repository"

    # The dump is removed whatever happens next. It is a second cleartext copy of
    # the database sitting next to the first one, and it has no job once restic
    # has it: a local file cannot survive the disk it is on, and that is the
    # failure this whole script exists for.
    trap cleanup_dump EXIT

    # One snapshot, two paths, and not two snapshots. A restore needs both files
    # to have come from the same moment: the secrets that were live when the
    # database was dumped are the ones that decrypt and match what is in it. Two
    # snapshots can drift apart by a night, and the pairing would then have to be
    # reconstructed by timestamp at exactly the wrong moment.
    #
    # `kolonie-db` stays on the snapshot so that the tag older snapshots carry
    # keeps meaning the same thing; `kolonie-env` is added so that "which
    # snapshots contain the secrets file" is one query.
    log "backing up $(basename "$DUMP_PATH") and $(basename "$ENV_FILE")"
    if ! restic backup \
            --host "$RESTIC_HOST_LABEL" \
            --tag kolonie-db \
            --tag kolonie-env \
            --quiet \
            "$DUMP_PATH" "$ENV_FILE"; then
        die "restic backup failed — the previous snapshot is still the newest one"
    fi

    # Ask the repository what it has, rather than trusting the exit code of the
    # command that just wrote to it. A backup is only a backup once the thing
    # that has to serve it during a restore says it is there.
    #
    # `snapshots latest` and NOT `snapshots --latest 1`, and the difference is not
    # stylistic. **`--latest N` is per (host, paths) group, not per repository:**
    # with two sets of paths in the repository it returns one snapshot for each,
    # oldest group first. This script had `--latest 1 | head -1` while every
    # snapshot held the same single path, so the grouping was invisible and the
    # answer happened to be right. Adding /opt/kolonie/.env created a second group
    # and the query started returning the newest snapshot *of the old shape* —
    # this morning's, without the secrets in it.
    #
    # It surfaced as the check below refusing the run on 2026-07-31, which is the
    # check doing its job on the code that wrote it. Anything grouping snapshots
    # by path is a trap here for as long as the path set can change.
    local newest
    newest=$(restic snapshots latest --host "$RESTIC_HOST_LABEL" --json 2>/dev/null \
        | grep -o '"short_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$newest" ] || die "backup reported success but the repository has no snapshot for $RESTIC_HOST_LABEL"

    # The same argument as reading the snapshot id back instead of trusting an
    # exit code, one level deeper. `restic backup` exiting 0 says the command
    # succeeded, not that both paths are in the snapshot — an excluded path, a
    # file that vanished mid-run, a future change to the invocation above. The
    # dump has the restore test to catch its absence; the secrets file had
    # nothing until this line.
    if ! restic ls "$newest" 2>/dev/null | grep -qxF "$ENV_FILE"; then
        die "snapshot $newest does not contain $ENV_FILE — the secrets are not backed up"
    fi

    log "snapshot $newest"

    # Structural integrity of the repository: are all the pack files the index
    # claims to have actually there. This does not download the data (that is
    # --read-data, and it would pull the whole repository every night), so it
    # catches an incomplete upload or a truncated index and not bit rot inside a
    # pack. Cheap while the repository is small; if it stops being cheap, this is
    # the line that moves to a weekly unit.
    if ! restic check --quiet; then
        die "snapshot $newest was written but the repository does not check out"
    fi

    # Written here rather than in the unit's ExecStopPost, so that a hand-run
    # counts too. This file is the only cheap answer to "when did a backup last
    # *succeed*" — the unit's own timestamps record when it last *ran*, and the
    # difference between the two is the entire failure mode this guards against.
    # health-report.sh reads it; see docs/disaster-recovery.md.
    ( umask 022; date -Is > "$WORK_DIR/.last-success" )
    chmod 644 "$WORK_DIR/.last-success" 2>/dev/null || true

    log "ok"
}

# Read-only. Safe to run at any time, including while a backup is in flight —
# it takes no lock and writes nothing.
do_verify() {
    require_config
    restic cat config >/dev/null 2>&1 || die "the repository is unreachable with the configured credentials"
    restic snapshots --host "$RESTIC_HOST_LABEL" --latest 5

    # What the newest snapshot actually holds. Paths only — `restic ls` prints
    # names, never contents, so this stays safe to run where the output is read
    # by someone who should not see the secrets themselves.
    echo "--- contents of the newest snapshot ---"
    restic ls latest 2>/dev/null | grep '^/' | grep -v '^/$' || true

    restic stats --host "$RESTIC_HOST_LABEL" --mode raw-data 2>/dev/null || true
}

# A restore that has not been performed is a hypothesis. This is the acceptance
# criterion of #4 made runnable, so that the next person does not have to invent
# the procedure while the production database is the thing at stake.
#
# It restores the newest snapshot into a throwaway database *inside the running
# Postgres container*, counts the rows in every table, compares them against the
# live database, and drops the throwaway again. It never writes to the live
# database — the only statements it sends there are SELECTs.
do_restore_test() {
    require_config

    # At file scope for the same reason DUMP_PATH is: the EXIT trap runs after
    # this function has returned, and a `local` would be empty by then. That
    # failure is quiet and it matters — the trap would send `DROP DATABASE IF
    # EXISTS ` with no name, and a full copy of production would be left in the
    # cluster with nothing scheduled to remove it. Caught by rehearsal case 13.
    SCRATCH_DB="restoretest_$(date +%Y%m%d%H%M%S)"
    log "restoring the newest snapshot into $SCRATCH_DB"

    docker_cmd exec "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d postgres \
        -c "CREATE DATABASE $SCRATCH_DB" >/dev/null || die "could not create $SCRATCH_DB"

    # Dropped on every exit path, including the failures below. A leftover
    # restore database is a copy of production nobody is watching.
    trap cleanup_scratch EXIT

    # restic dump streams the file out of the snapshot without unpacking the
    # whole repository to disk; `docker exec -i` is what forwards it into psql.
    # Without the -i, psql receives nothing, exits 0, and prints nothing at all —
    # which is indistinguishable from a restore that worked. docker_pipe rather
    # than docker_cmd for the same reason, one layer up.
    if ! restic dump latest "$WORK_DIR/$DUMP_NAME" \
            | docker_pipe exec -i "$PG_CONTAINER" psql -q -U "$POSTGRES_USER" -d "$SCRATCH_DB" -v ON_ERROR_STOP=1 >/dev/null; then
        die "restore into $SCRATCH_DB failed"
    fi

    # Exact counts, not `n_live_tup`. That column is the planner's estimate; it
    # is whatever the last ANALYZE saw, and on a freshly restored database it
    # reads 0 for every table until one runs. A comparison built on it would
    # report a perfect restore and a broken one identically.
    local query="
        SELECT relname,
               (xpath('/row/c/text()',
                      query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname),
                                   false, true, '')))[1]::text::bigint AS rows
        FROM pg_stat_user_tables ORDER BY relname"

    local live restored rc
    live=$(docker_cmd exec "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$query")
    restored=$(docker_cmd exec "$PG_CONTAINER" psql -U "$POSTGRES_USER" -d "$SCRATCH_DB" -tAc "$query")

    echo "--- live vs restored (table|rows) ---"
    diff <(echo "$live") <(echo "$restored")
    rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "identical: $(echo "$live" | grep -c .) tables, $(echo "$restored" | awk -F'|' '{s+=$2} END {print s+0}') rows"
    else
        echo
        echo "The two databases differ. That is not automatically a failure — the" >&2
        echo "live database keeps taking writes while the snapshot does not — but" >&2
        echo "every differing line has to be explainable by that." >&2
    fi
    return "$rc"
}

case "${1:-backup}" in
    backup)       do_backup ;;
    verify)       do_verify ;;
    restore-test) do_restore_test ;;
    *) die "usage: $0 {backup|verify|restore-test}" ;;
esac
