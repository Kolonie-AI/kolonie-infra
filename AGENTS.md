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
                                            ├── kolonie-backend (api.kolonie.ai)
                                            ├── kolonie-frontend (kolonie.ai)
                                            ├── kolonie-academy (academy.kolonie.ai)
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
