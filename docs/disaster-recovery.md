# Disaster Recovery

## Backup Strategy

### Database (PostgreSQL)
- **Frequency:** Daily automated backup
- **Retention:** 7 daily, 4 weekly, 3 monthly
- **Location:** External storage (S3-compatible or another VPS)
- **Method:** `pg_dump` via cron job

### Docker Volumes
- **Frequency:** Weekly
- **Retention:** 4 weekly
- **Location:** Same as database backups
- **Method:** `tar` of Docker volume directories

### Configuration
- **Source of truth:** This GitHub repository
- **Secrets:** Stored in `.env` on VPS (backup separately)
- **Recovery:** Clone repo, copy .env, docker compose up

## Recovery Procedures

### Scenario 1: Service Crash
```
1. docker compose logs <service> — check error
2. docker compose restart <service> — try restart
3. If persistent: docker compose down && docker compose up -d
4. If still broken: rollback via ./scripts/rollback.sh
```

### Scenario 2: Database Corruption
```
1. Stop all services: docker compose down
2. Restore from latest backup:
   docker compose up -d postgres
   docker exec -i kolonie-postgres psql -U kolonie < backup.sql
3. Restart services: docker compose up -d
4. Verify data integrity
```

### Scenario 3: VPS Compromise
```
1. Immediately: Change all passwords and API keys
2. Provision new VPS
3. Clone kolonie-infra repo
4. Restore .env from secure backup
5. Restore database from backup
6. docker compose up -d
7. Investigate breach, update security model
```

### Scenario 4: VPS Provider Outage
```
1. Provision VPS at alternative provider (Hetzner, DigitalOcean)
2. Clone kolonie-infra repo
3. Restore .env and database backup
4. Update DNS (Cloudflare) to new IP
5. docker compose up -d
```

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
code tolerates the new schema. Its expensive branch remains expensive because
there is no automated backup yet (kolonie-infra#4); with that, step 2 stops
being a judgement call.

**A rollback with nothing recorded does nothing.** On a host that has not
completed a deploy since #12, both `rollback()` and `scripts/rollback.sh` say so
and exit without touching a container — there is no known-good version to return
to, and tearing down containers that are serving would turn a failed deploy into
an outage.

Until then, the cheap insurance before a deploy carrying a destructive
migration is a dump — one command, and it turns step 2 into a decision instead
of a gamble:

```bash
ssh <host> 'docker exec kolonie-postgres pg_dump -U kolonie kolonie' > pre-deploy.sql
```

## Recovery Time Objectives

| Scenario | Target Recovery Time |
|----------|---------------------|
| Service crash | < 5 minutes |
| Database restore | < 30 minutes |
| Full VPS rebuild | < 1 hour |
| Provider migration | < 4 hours |

## Automated Backups (TODO)

Set up cron job on VPS:
```bash
# /etc/cron.d/kolonie-backup
0 3 * * * root /opt/kolonie/scripts/backup.sh
```

Backup script uploads to external storage (S3, Hetzner Storage Box, or similar).

## Testing Backups

Backups that are not tested are not backups. Schedule quarterly restore drills:
1. Spin up temporary VPS
2. Restore from backup
3. Verify all services work
4. Document any issues
5. Tear down temporary VPS
