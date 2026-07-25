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
