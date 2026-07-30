# Disaster Recovery

## Backups

### What exists

A daily `pg_dump` of the Colony's database, stored in a [restic](https://restic.net)
repository on an S3-compatible object store off this host (#4, 2026-07-30).

| | |
|---|---|
| **Schedule** | `kolonie-backup.timer`, daily at 03:00, `Persistent=true` |
| **Runs** | `scripts/backup.sh backup`, on the host — not in Compose |
| **Working directory** | `/var/backups/kolonie` |
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

### Restoring

Everything below assumes the credentials are loaded:

```bash
sudo -i
set -a; . /opt/kolonie/backup.env; set +a
export RESTIC_CACHE_DIR=/var/cache/restic
```

```bash
restic snapshots                      # what is available
./scripts/backup.sh verify            # newest snapshots plus repository size
restic dump latest /var/backups/kolonie/kolonie.sql > /tmp/restore.sql
```

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

An earlier run the same day differed by one row in four tables
(`email_challenges`, `pow_challenges`, `submissions`, `verifications`) — one
registration completing between the snapshot and the comparison, which is the
expected shape of a benign difference.

Re-run it after any change to the schema, to `backup.sh`, or to the Postgres
version, and add a row above.

### Rebuilding this on a new host

The scripts and units arrive with the checkout; three things do not.

```bash
sudo apt-get install -y restic

# 1. credentials — repository URL, restic password, object-store key
sudo install -m 600 /dev/stdin /opt/kolonie/backup.env <<'EOF'
RESTIC_REPOSITORY=...
RESTIC_PASSWORD=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
EOF

# 2. the units, copied rather than symlinked — the same convention as
#    kolonie-origin-firewall. A change to the unit in this repository does NOT
#    reach the host on deploy; re-run this install and daemon-reload.
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

- **Docker volumes other than the database.** Traefik's `acme.json` is the only
  one holding state that is not reproducible, and it re-issues on demand.
- **`/opt/kolonie/.env`.** It holds every production secret and it is not in this
  repository by design. It is not in the restic repository either — back it up
  where secrets belong, not where the database goes. `.env.example` lists what it
  must contain.
- **The repository password.** Obviously, but it is the mistake that turns a
  complete backup into nothing. See "The two passwords".

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
4. Restore .env from secure backup
5. Restore database from backup (see "Rebuilding this on a new host")
6. docker compose up -d
7. Investigate breach, update security model
```

The restic password does **not** need rotating for confidentiality — an attacker
who had the host had the plaintext database anyway. It needs rotating only if you
want the old snapshots to become unreadable to them, and that costs you the
snapshots too. Rotate the object-store key first; that removes their access to
the repository without destroying it.

### Scenario 4: VPS Provider Outage

```
1. Provision VPS at an alternative provider
2. Clone kolonie-infra repo
3. Restore .env and the database (see "Rebuilding this on a new host")
4. Update DNS (Cloudflare) to new IP
5. docker compose up -d
```

The restic repository is reachable from anywhere with the credentials, so the
replacement host does not depend on the old one being alive.

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

## Recovery Time Objectives

| Scenario | Target Recovery Time |
|----------|---------------------|
| Service crash | < 5 minutes |
| Database restore | < 30 minutes |
| Full VPS rebuild | < 1 hour |
| Provider migration | < 4 hours |

## Configuration

- **Source of truth:** this GitHub repository
- **Secrets:** `/opt/kolonie/.env` on the host, backed up separately — see
  "What is not backed up"
- **Recovery:** clone repo, restore `.env`, `docker compose up -d`
