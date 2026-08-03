# Disaster Recovery

## Backups

### What exists

A daily `pg_dump` of the Colony's database, **`/opt/kolonie/.env`**, and
**`/opt/kolonie/secrets/`**, stored in a [restic](https://restic.net) repository
on an S3-compatible object store off this host (#4, 2026-07-30; the secrets file
added in #45, 2026-07-31; the credential *files* in kolonie-platform#105,
2026-08-01).

They go into **one** snapshot, not three. A restore needs them from the same
moment: the secrets that were live when the database was dumped are the ones that
match what is inside it. Separate snapshots drift apart by a night, and the
pairing would have to be reconstructed by timestamp at exactly the wrong moment.

| | |
|---|---|
| **Schedule** | `kolonie-backup.timer`, daily at 03:00, `Persistent=true` |
| **Runs** | `scripts/backup.sh backup`, on the host — not in Compose |
| **Working directory** | `/var/backups/kolonie` |
| **In the snapshot** | `/var/backups/kolonie/kolonie.sql`, `/opt/kolonie/.env`, `/opt/kolonie/secrets/` |
| **Tags** | `kolonie-db`, `kolonie-env`, and `kolonie-secrets` when the directory has files |
| **Retention** | every snapshot is kept; nothing prunes |
| **Encryption** | restic, client-side, before anything leaves the host |
| **Configuration** | `/opt/kolonie/backup.env`, root-only, `0600` |

`backup.sh` documents *why* it is built this way — why on the host rather than in
a container, why the dump is written to a file before restic sees it, and why it
is not compressed first. That reasoning is not repeated here; read the header of
the script before changing it.

### Retention: everything, on purpose

restic deduplicates and then compresses, so consecutive dumps of a database that
changes slowly cost very little after the first. Three snapshots on the day this
was set up held 425 KiB of dumps in 106 KiB of repository. Keeping every snapshot
is therefore affordable, and it removes a whole class of mistake: there is no
retention policy to get wrong, and no `forget` that can delete the snapshot
someone needed.

When that stops being true, one line in `do_backup` starts a retention policy,
and the numbers below are the ones this document used to promise:

```bash
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
```

Adding it has a consequence at the object store, not only here: restic then
deletes files, and a bucket configured to keep every version will retain those
deletions as hidden versions forever. Set the bucket to keep only the current
version at the same time, or the pruning saves nothing.

### The two passwords

The repository is encrypted with a key that is not recoverable from the backup
itself. There are **two** repository passwords, and either one opens it:

| Key | User | Where it lives |
|---|---|---|
| `eb806547` | `backup` | `/opt/kolonie/backup.env` on the host |
| `6f48c96b` | `maintainer` | the maintainer's password manager, off this host |

Two rather than one, because a single key stored on the machine being backed up
is not a key at all — the scenario where the backup is needed is often the
scenario where that host is gone. Neither password appears in this repository.

Adding a third, if someone else needs independent access:

```bash
restic key add --user <name> --host offline
restic key list
```

### Why the secrets file is in here, against what this document used to say

Until 2026-07-31 this document argued the opposite, and said so under *What is not
backed up*: secrets must not go where the database goes. That was reversed in #45,
and the argument is recorded here rather than edited away.

**The separation bought less than it read like.** `backup.env` is root-only, so
anyone who can read the object-store credentials is already root on this host —
and root can read `/opt/kolonie/.env` directly. The only case the split defended
against was the object-store key *and* the repository password leaking with no
host access at all, and an attacker holding both already has every user record in
the database.

**Against that stood a hole in the backup itself, not merely in the rebuild.**
`BAN_MARK_SALT` lives in `.env` and salts the ban marks stored *in the database*.
`packages/db/src/ban-salt.ts` states that every existing mark stops matching the
day that value moves. A restore without it brings the rows back permanently
unmatchable — so part of what the snapshot held was worthless without a file the
snapshot did not hold.

**And it only became possible on the day it was done.** While the repository
password existed nowhere but the host, "put everything in restic" was a circle.
The password reached the maintainer's vault on 2026-07-31, which is what
terminates the chain outside this machine.

Two things follow that are worth having in their own right. The retention policy
never prunes, so a daily snapshot of `.env` is a **version history** of it —
`restic diff` shows the day a secret changed, and a clobbered file comes back from
yesterday. And a damaged `.env` now fails the whole run, database included, which
is the uncomfortable half: see *A damaged `.env` stops the database backup too*
below.

### Why the credential *files* are in here as well

`.env` stopped being the whole of this host's secrets on 2026-08-01. Two
credentials are files, because neither fits in a `.env`:

| File | Read by | What its absence costs |
|---|---|---|
| `/opt/kolonie/secrets/pgadmin.htpasswd` | Traefik | `db.kolonie.ai` answers nothing — Traefik drops a router whose `usersFile` is missing |
| `/opt/kolonie/secrets/kolonie-triage-app.pem` | `support-triage-runner` | the support queue is read and nothing is ever filed |

**Both fail silently, and that is the argument.** Each is designed to degrade
rather than crash — absent means shut, not open — so a host rebuilt from a
snapshot without them comes back looking entirely healthy, passes every health
check, and has quietly lost two capabilities. Nothing would say so until somebody
opened `db.kolonie.ai` or wondered why no ticket had ever been triaged.

That is the same hole #45 closed for `BAN_MARK_SALT`: part of the backup was
conditional on a secret that was not in it.

**Absent is not an error; damaged is.** A host with neither pgAdmin nor the
GitHub App has no such directory, and the database backup is not hostage to it —
the run says `secrets: … does not exist — nothing to include` and carries on. But
a host that *has* the files and writes a snapshot without them fails the run,
because `backup.sh` reads the snapshot's listing back rather than trusting the
exit code of the write. Rehearsal cases 20 through 20d hold both halves.

**What is still out is `backup.env`.** It holds the repository URL, its password
and the object-store credentials, and backing it up inside the repository it
unlocks is circular. It belongs in the maintainer's password manager. The rule:
everything the host needs to come back goes into restic; what unlocks restic goes
into the vault.

### Restoring

Everything below assumes the credentials are loaded:

```bash
sudo -i
set -a; . /opt/kolonie/backup.env; set +a
export RESTIC_CACHE_DIR=/var/cache/restic
```

```bash
restic snapshots                      # what is available
./scripts/backup.sh verify            # newest snapshots, contents, repository size
restic ls latest                      # which paths this snapshot holds
```

**The secrets come out first, and the database second.** That order is not a
preference: the stack cannot start without `.env`, and the database cannot be
loaded into a Postgres that is not running.

```bash
restic dump latest /opt/kolonie/.env > /opt/kolonie/.env
chmod 600 /opt/kolonie/.env
chown ubuntu:ubuntu /opt/kolonie/.env

# The credential files. `restic dump` on a directory writes a tar, which is what
# makes this one command rather than one per file — and it stays correct when a
# third credential is added without anybody editing this runbook.
mkdir -p /opt/kolonie/secrets
restic dump latest /opt/kolonie/secrets | tar -x -C /opt/kolonie/secrets --strip-components=1
chmod 700 /opt/kolonie/secrets
chmod 600 /opt/kolonie/secrets/*
chown -R ubuntu:ubuntu /opt/kolonie/secrets

restic dump latest /var/backups/kolonie/kolonie.sql > /tmp/restore.sql
```

**Traefik does not notice the htpasswd appearing.** It resolves `usersFile` when
it builds the middleware and does not watch `/secrets`, so a file restored under
a running Traefik is a file Traefik never looks for: it keeps the middleware it
failed to build, drops the router, and `db.kolonie.ai` answers 404 with nothing
in the log to say why. `docker restart kolonie-traefik` after restoring, and do
not expect a reload — touching a file under `traefik/dynamic` does not do it
either. Measured on 2026-08-01, not assumed.

Restoring `.env` over a host that still has a working one is how you replace a
current secret with an older one. On a host that is not a bare rebuild, dump it
somewhere else and diff first.

The dump is plain SQL. It restores into an **empty** database — it carries no
`DROP` statements, so loading it over existing data produces duplicate-key errors
rather than a clean overwrite. That is deliberate: a dump that silently replaces
a live database is a loaded gun.

```bash
# into a scratch database, to look before committing to anything
docker exec kolonie-postgres psql -U kolonie -d postgres -c "CREATE DATABASE restore_check"
restic dump latest /var/backups/kolonie/kolonie.sql \
  | docker exec -i kolonie-postgres psql -U kolonie -d restore_check -v ON_ERROR_STOP=1
```

`docker exec -i`. Without the `-i`, stdin is not forwarded: `psql` receives
nothing, exits 0, and prints nothing — indistinguishable from a restore that
worked.

### Verifying that the backups still happen

The failure mode of a backup system is not corruption, it is silence. Three
places answer it, cheapest first:

```bash
./scripts/health-report.sh | ./scripts/health-triage.sh   # `backup` row; degraded after 36h
systemctl list-timers kolonie-backup.timer
journalctl -u kolonie-backup.service -n 50
```

The `backup` row reads `/var/backups/kolonie/.last-success`, which is written
only after a snapshot has been confirmed *by the repository* and the repository
has passed `restic check`. A run that fails leaves the previous timestamp alone,
so a backup that has stopped shows its true age rather than resetting each night.

### Restore tests

An untested backup is a hypothesis. `scripts/backup.sh restore-test` restores the
newest snapshot into a throwaway database inside the running Postgres container,
compares exact row counts per table against the live database, and drops the
throwaway again. It never writes to the live database.

Differences are not automatically failures — the live database keeps taking
writes while a snapshot does not — but every differing line has to be explainable
by that.

| Date | Snapshot | Result |
|---|---|---|
| 2026-07-30 | `78befaa7` | **Pass.** 20 tables, 338 rows, identical to live. |
| 2026-07-31 | `cfe7f892` | **Pass.** 31 tables, 452 rows, identical to live — the first snapshot carrying `.env` as well, re-run because #45 changed the shape of a snapshot. `restic dump latest <path>` still resolves the dump with two paths in it. |

The `.env` in that snapshot was checked separately, and not by restoring it over
a working host: dumped out of the repository and compared by SHA-256 against the
live file. Identical, 19 assignments, mode `0600` and ownership preserved by
restic. Comparing hashes rather than printing either copy is the form that check
has to take (AGENTS.md §11).

An earlier run the same day differed by one row in four tables
(`email_challenges`, `pow_challenges`, `submissions`, `verifications`) — one
registration completing between the snapshot and the comparison, which is the
expected shape of a benign difference.

Re-run it after any change to the schema, to `backup.sh`, or to the Postgres
version, and add a row above.

### Rebuilding this on a new host

The scripts and units arrive with the checkout; three things do not. Step 1 is the
only one that comes from a human — everything after it is recoverable from what
step 1 unlocks.

```bash
sudo apt-get install -y restic

# 1. credentials — repository URL, restic password, object-store key.
#    From the maintainer's password manager. This is the single input the rebuild
#    cannot derive, which is why it is the single thing kept out of the snapshot.
sudo install -m 600 /dev/stdin /opt/kolonie/backup.env <<'EOF'
RESTIC_REPOSITORY=...
RESTIC_PASSWORD=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
EOF

# 1b. the compose secrets, out of the snapshot rather than out of a human (#45).
#     Before the units, because a backup run refuses to start without this file.
sudo -i
set -a; . /opt/kolonie/backup.env; set +a
restic dump latest /opt/kolonie/.env > /opt/kolonie/.env
chmod 600 /opt/kolonie/.env && chown ubuntu:ubuntu /opt/kolonie/.env

# 2. the units, copied rather than symlinked — the same convention as
#    kolonie-origin-firewall. A change to the unit in this repository does NOT
#    reach the host on deploy; re-run this install and daemon-reload.
#
#    Copy *out of* the checkout, never create files in it as root. /opt/kolonie
#    is a git checkout the deploy resets as the `ubuntu` user, and a root-owned
#    file or directory inside it makes `git reset --hard` fail with "Permission
#    denied" — which breaks every deploy, not just this one. That is exactly how
#    adding these two units broke the deploy on 2026-07-30: `systemd/` had been
#    left owned by root. Check with `ls -ld /opt/kolonie/*` if a deploy ever
#    fails at the git step.
sudo install -m 644 systemd/kolonie-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kolonie-backup.timer

# 3. prove it
sudo systemctl start kolonie-backup.service
journalctl -u kolonie-backup.service -n 20
```

On a host that is restoring rather than starting fresh, do not run `restic init`
— the repository already exists, and initialising over it is how you get an empty
one.

### What is not backed up

The rule, since #45: **everything the host needs to come back goes into restic;
what unlocks restic goes into the vault.** So what is left out is left out because
it is one of those two, and not by accident.

- **Docker volumes other than the database.** Traefik's `acme.json` is the only
  one holding state that is not reproducible, and it re-issues on demand.
- **`/opt/kolonie/backup.env`.** The repository URL, its password and the
  object-store credentials. Backing it up inside the repository it unlocks is a
  circle: you would need it to reach the copy of it. It lives in the maintainer's
  password manager, and that is the one thing this whole scheme depends on being
  kept somewhere else. See "The two passwords".
- **`.env.bak-*` and `.env.example`.** `backup.sh` names the one path it backs up
  rather than backing up a directory, so the neighbours are not swept along.
  `.env.example` is in this repository anyway.

`/opt/kolonie/.env` **was** on this list until 2026-07-31 and is now in the
snapshot — see the section above for why the reasoning was reversed.

### A damaged `.env` stops the database backup too

`backup.sh` checks the secrets file in preflight: it must exist, be non-empty, and
hold at least `KOLONIE_ENV_MIN_ASSIGNMENTS` assignments — ten, against the
nineteen the host carried on 2026-07-31. Below that it is assumed truncated rather
than small, and **the whole run is refused, including the database dump**.

That is deliberate and it is the uncomfortable half of #45. The alternative is to
snapshot the database anyway and warn about the file, which writes a snapshot that
looks complete and is not — discovered by the person restoring it, who has nothing
left to check it against. Every other branch in that script refuses to write
rather than write something partial.

What makes it affordable is that it cannot be silent. The run fails, the unit
fails, `.last-success` keeps its old timestamp, and the `backup` row goes red after
36 hours. The trigger is nearly always an edit made seconds earlier by the person
now reading the error.

The script counts assignments and never reads a value; no part of it may put the
contents of that file into a variable, a log line or a message (AGENTS.md §11).
Rehearsal case 20 asserts exactly that across five runs, including the failing
ones.

### One accepted leak

restic writes the machine's hostname into the lock files it creates during a run,
in cleartext, alongside the encrypted data. Snapshots and repository keys do not
carry it — those are set to a fixed logical name on purpose — but lock files are
not configurable. Anyone able to read that is someone holding the object-store
credentials, and they can already read the encrypted repository; the marginal
disclosure is judged acceptable rather than worth the machinery of running restic
in a separate UTS namespace.

## Recovery Procedures

### Scenario 1: Service Crash

```
1. docker compose logs <service> — check error
2. docker compose restart <service> — try restart
3. If persistent: docker compose down && docker compose up -d
4. If still broken: rollback via ./scripts/rollback.sh
```

### Scenario 2: Database Corruption

The database is the one thing here that cannot be rebuilt from a registry or a
git remote, and `governance/treasury.md` in kolonie-docs makes the coin ledger
the single source of truth for every balance in the Colony. Take the time to look
before overwriting anything.

```
1. Stop what writes, not the database itself:
     docker compose stop api verifier-runner moderation-runner

2. Restore into a scratch database first and look at it. Restoring straight over
   the live one destroys the evidence of what went wrong, and does it before you
   know whether the snapshot is better than what you have.
     (see "Restoring" above)

3. Compare. `backup.sh restore-test` prints per-table row counts of the snapshot
   against the live database — read the difference before deciding.

4. Promote the restored copy, rather than loading SQL over live tables:
     docker exec kolonie-postgres psql -U kolonie -d postgres \
       -c "ALTER DATABASE kolonie RENAME TO kolonie_broken" \
       -c "ALTER DATABASE restore_check RENAME TO kolonie"

5. docker compose up -d, then ./scripts/healthcheck.sh

6. Keep `kolonie_broken` until the incident is written up. It is the only record
   of what happened.
```

### Scenario 3: VPS Compromise

```
1. Immediately: rotate all passwords and API keys, including the object-store
   application key — a compromised host had it in /opt/kolonie/backup.env
2. Provision new VPS
3. Clone kolonie-infra repo
4. Rebuild backup.env from the vault, then restore .env out of the snapshot
   (see "Restoring") — but see the warning below before reusing those values
5. Restore database from backup (see "Rebuilding this on a new host")
6. docker compose up -d
7. Investigate breach, update security model
```

**Step 4 is the one that differs from every other scenario.** Everywhere else the
snapshot of `.env` is what you want. Here it holds the secrets the attacker had:
restore it to know *what* has to be rotated, and rotate every value in it before
the stack serves traffic. It is an inventory, not a configuration.

The restic password does **not** need rotating for confidentiality — an attacker
who had the host had the plaintext database anyway. It needs rotating only if you
want the old snapshots to become unreadable to them, and that costs you the
snapshots too. Rotate the object-store key first; that removes their access to
the repository without destroying it.

### Scenario 4: VPS Provider Outage

```
1. Provision VPS at an alternative provider
2. Clone kolonie-infra repo
3. Rebuild backup.env from the vault, restore .env, then the database
   (see "Rebuilding this on a new host")
4. Update DNS (Cloudflare) to new IP
5. docker compose up -d
```

The restic repository is reachable from anywhere with the credentials, so the
replacement host does not depend on the old one being alive. Since #45 that is
true of the secrets as well as the data: the only input this scenario needs from
outside the repository is the vault entry that opens it.

### Scenario 5: The migration succeeded and the health check then failed

`deploy.sh` migrates between `pull` and `up -d`, so by the time a health check
fails the schema has already moved forward. That asymmetry is the thing to hold
on to: **the containers can go back and the database cannot.** Since #12,
`rollback()` genuinely does bring back the previous *build* — it re-deploys the
digests in `state/deployed.env`, written after the last health check that
passed. So what you get is the old code against the new schema, on purpose and
reliably, rather than the same failing image pulled a second time.

Take it in this order, and do not start by rolling back.

```
1. Read why. The migration is not the suspect until it is:
   docker compose logs --tail 100 api
   Deploys fail for the reasons they have always failed — a missing variable,
   an unreachable image — and those are unrelated to the schema.

2. Ask whether the old code can live with the new schema.
   Additive migrations (a new table, a new nullable column) it can: the old
   code simply does not use them. A rename, a NOT NULL on an existing column
   or a dropped column it cannot.

   Additive  -> `./scripts/rollback.sh`, then fix forward. The stack is serving
                again within minutes and the extra schema is inert.
   Otherwise -> do NOT roll back the containers. A rollback here produces the
                one state worse than being down: the site up and writing wrong
                rows. Fix forward, or restore per Scenario 2 and accept the
                data loss between the backup and now.

3. Whichever path: the fix goes through a migration in kolonie-platform's
   packages/db. Never `psql` against the live database by hand — the next
   deploy would migrate from bookkeeping that no longer matches the schema,
   and the failure surfaces far from the cause.
```

Note what this scenario costs, and where it is being paid down. The containers
can now be returned to a known-good build (#12, 2026-07-28), so step 2 is no
longer *"can we roll back at all"* but the narrower question of whether the old
code tolerates the new schema. Its expensive branch is now bounded too: since #4
there is a nightly snapshot, so "restore and accept the data loss" means losing
hours rather than everything.

**A rollback with nothing recorded does nothing.** On a host that has not
completed a deploy since #12, both `rollback()` and `scripts/rollback.sh` say so
and exit without touching a container — there is no known-good version to return
to, and tearing down containers that are serving would turn a failed deploy into
an outage.

The cheap insurance before a deploy carrying a destructive migration is still a
dump taken *now* rather than at 03:00, and it is one command:

```bash
sudo /opt/kolonie/scripts/backup.sh backup
```

### Scenario 6: `migrations: none pending` and the tables are not there

**What it looks like.** A deploy reports `Migrations: done`, the migrator says
`none pending, N already applied`, and the schema the new code needs is absent.
The deploy then fails somewhere downstream — the seed, or a container that
cannot start — and the message names that step rather than the cause.

**Why it happens.** Drizzle's migrator does not track migrations individually.
It reads the newest `created_at` in `drizzle.__drizzle_migrations` and applies
every journal entry whose `when` is greater than that. One entry stamped in the
future therefore swallows **every migration generated after it** until the wall
clock catches up, silently, while reporting that there is nothing to do.

`drizzle-kit` takes `when` from the clock of whichever machine generated the
file, so two contributors on two machines are enough to produce it. It happened
on 2026-08-03: `0079` was stamped twenty-two hours ahead, five later migrations
never ran, and three deploys reported success before the fourth failed in the
seed.

**How to confirm it.** Compare what the image carries with what the database
believes:

```bash
docker run --rm --entrypoint sh ghcr.io/kolonie-ai/kolonie-api:latest \
    -c 'ls /app/packages/db/drizzle/*.sql | wc -l'
docker exec -i kolonie-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c 'select count(*) from drizzle.__drizzle_migrations'
```

Two different numbers with `none pending` is this. Then find the offender —
any row whose `created_at` is not between its neighbours':

```bash
docker exec -i kolonie-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
    'select id, left(hash,16), created_at,
            to_timestamp(created_at/1000) at time zone '"'"'UTC'"'"' as ts
       from drizzle.__drizzle_migrations order by id desc limit 10'
```

**The repair.** Move the offending row's `created_at` to one millisecond after
its predecessor's, so that file order and timestamp order agree again. Identify
the row **by hash** and not by position — `sha256sum` of the `.sql` file matches
the `hash` column — and state the old value in the `where` clause so the update
cannot hit a row that has since changed:

```sql
update drizzle.__drizzle_migrations
   set created_at = <predecessor + 1>
 where id = <id> and hash like '<first 16 of the hash>%' and created_at = <the future value>;
```

Then run the migrator again; it applies everything that was skipped, in order.
Take a dump first — it is one command, above — although this touches only
bookkeeping and the migrations themselves are the same ones the deploy would
have run.

**Repair the row, not only the migrations it hid.** This is the half that was
missed on 2026-08-03 and it is why the incident had two dates. Running the
skipped migrations makes the deploy green and leaves the future stamp sitting in
the table, where it hides nothing at all until the next migration is authored
below it — nine days, in the recorded case, between a repair that looked complete
and the second failure it guaranteed. The `update` above is the repair; applying
the migrations is the consequence of it. If you have already run the migrator and
the row still carries its old value, you are not finished.

**What stops it recurring.** Four things, in the order they would catch it:

1. `packages/db/src/journal.test.ts` in `kolonie-platform` fails if the journal's
   timestamps are not strictly increasing in `idx` order — along with the three
   other invariants that make the journal safe to merge — so the commit that
   writes one cannot reach `main`. It reads the journal from disk and needs no
   database, so it runs on the machine doing the merging.
2. The migrator itself compares the journal against `__drizzle_migrations` after
   migrating and exits non-zero naming what is missing — **matched on the
   timestamp and not on the hash**, because a migration whose file was edited
   after it ran would otherwise look exactly like one that never ran. This
   repository has such a file (`0039_backfill_task_attempts`).
3. `npm run check:drift -w @kolonie-ai/db` compares each recorded `created_at`
   against the journal `when` for the same migration, matched **by hash** —
   which is the question none of the others asks, and the one whose answer was
   wrong for nine days while every other signal read healthy. Rows that hash to
   no file cannot be checked and are counted rather than reported, so
   `0039_backfill_task_attempts` does not cry wolf; the count is printed, and a
   second unmatched row is worth asking about. The migrator runs the same check
   and refuses the deploy on a finding, but **this one runs without a deploy**,
   which is the whole point: the state is dormant, so nothing prompts anybody to
   look for it.
4. `deploy.sh` counts the `.sql` files in the image against the rows in the
   database, from outside both, which is the one thing the migrator cannot see:
   an image that is not the one this deploy pulled reports `none pending`
   perfectly consistently and is wrong about the only thing that matters.

The first protects the repository. The rest are for a database that has already
drifted, which no test reading only the repository can reach.

## Recovery Time Objectives

| Scenario | Target Recovery Time |
|----------|---------------------|
| Service crash | < 5 minutes |
| Database restore | < 30 minutes |
| Full VPS rebuild | < 1 hour |
| Provider migration | < 4 hours |

## Configuration

- **Source of truth:** this GitHub repository
- **Secrets:** `/opt/kolonie/.env` on the host, in the nightly snapshot since #45.
  It is still edited by hand there, so the snapshot is a backup and a history —
  not a source of truth
- **The one thing kept elsewhere:** `/opt/kolonie/backup.env`, in the maintainer's
  password manager. Everything above is recoverable from it and nothing recovers
  it
- **Recovery:** rebuild `backup.env` from the vault, clone repo, `restic dump`
  `.env`, `docker compose up -d`, `restic dump` the database
