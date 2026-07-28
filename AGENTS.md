# AGENTS.md — Kolonie AI Infrastructure

## What This Repo Does

This is the Infrastructure as Code repository for Kolonie AI. It contains Docker Compose configurations, Traefik reverse proxy setup, and GitHub Actions deployment pipelines.

## Conventions

- Docker Compose v2 syntax
- Traefik v3 for reverse proxy
- PostgreSQL 16 as database
- All services on a shared `kolonie` Docker network
- Environment variables via `.env` file (never commit secrets)
- GitHub Actions for CI/CD

## Architecture

```
Internet → Cloudflare → Traefik (80/443) → Docker Network
                                            ├── kolonie-api (api + academy + mcp + challenge)
                                            ├── kolonie-website (kolonie.ai)
                                            ├── kolonie-verifier-runner (no ingress)
                                            └── postgres (internal only)
```

## Key Files

- `docker-compose.yml` — Production compose file
- `docker-compose.dev.yml` — Local development override
- `traefik/traefik.yml` — Static Traefik configuration
- `scripts/deploy.sh` — Deployment script
- `.github/workflows/deploy.yml` — GitHub Actions pipeline

## Rules for Coding Agents

1. **Never commit secrets.** Use `.env` files and GitHub Secrets.
2. **Test locally first.** Use `docker-compose.dev.yml` for local testing.
3. **Health checks required.** Every service must expose `/health`.
4. **Rollback on failure.** Deployment script handles this automatically.
5. **No force-push on main.** All changes via PR.
6. **Cross-repo awareness.** Service images come from other kolonie-* repos.

## How to Add a New Service

1. Add service definition to `docker-compose.yml`
2. Add Traefik labels for routing
3. Add health check endpoint
4. Update this README with service info
5. Test with `docker-compose.dev.yml`
6. Submit PR

## How to Modify Traefik Routing

1. Edit `traefik/traefik.yml` for static config
2. Edit service labels in `docker-compose.yml` for dynamic routing
3. Test locally before deploying
4. Submit PR

## Documentation

This repo contains both code AND documentation about infrastructure decisions:

- `ARCHITECTURE.md` — Decision log and reasoning
- `docs/scaling-strategy.md` — How we grow from VPS to global
- `docs/open-source-strategy.md` — Why and when we go public
- `docs/security-model.md` — Threat model and defenses
- `docs/cost-projections.md` — Infrastructure cost planning
- `docs/disaster-recovery.md` — Backup and recovery

When changing infrastructure, update the relevant docs too.

## Dependencies

- Docker + Docker Compose on VPS
- GitHub Actions for deployment
- Cloudflare for DNS
- Other kolonie-* repos for service images

## Deployment

Push to `main` triggers automatic deployment via GitHub Actions.
Manual deployment: `ssh <user>@<vps-host> 'cd /opt/kolonie && ./scripts/deploy.sh'`

> **Note:** VPS IP is never stored in this repo. All access goes through Cloudflare. Use environment variables or GitHub Secrets for the VPS host.

### Profiles

`--profile full` deploys the application services **that exist**: `api` and
`verifier-runner`. The website sits in its own `website` profile because its
image has never been built, and `docker compose pull` fails the entire command
for one missing image — taking the working images down with it. Add
`--profile website` to `detect_profile()` in `scripts/deploy.sh` once
`ghcr.io/kolonie-ai/kolonie-website` is published.

## Looking at the deploy host

**Do not reason about the host. Look at it.**

Run the **Diagnose VPS** workflow — `gh workflow run diagnose.yml`, then read the
run log. It is read-only and reports what is actually there: which variables
`/opt/kolonie/.env` defines, whether `docker compose` interpolates, which
containers run, which commit is checked out.

It prints variable **names**, never values. Keep it that way if you extend it: a
workflow log is not a private place.

This exists because of #7. Every deploy had failed for days — `.env` defines
`CLOUDFLARE_API_TOKEN`, `docker-compose.yml` demanded `CLOUDFLARE_DNS_API_TOKEN`
— and each failure was attributed to the known GHCR credential problem instead of
being read. One workflow run would have settled it at any point.

Direct SSH access, where a maintainer or agent has it, is fine for reading. Use
the workflow when the answer belongs somewhere the next agent will find it.
**Writing to the host still needs the maintainer's confirmation** — see the
kolonie-docs `AGENTS.md` §8.
