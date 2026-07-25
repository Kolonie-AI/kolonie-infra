# Kolonie AI — Infrastructure

Infrastructure as Code for Kolonie AI. Docker Compose, Traefik, deployment pipelines.

## Structure

```
kolonie-infra/
├── README.md
├── docker-compose.yml          # Main compose file (Traefik + services)
├── docker-compose.dev.yml      # Local development override
├── .env.example                # Environment variables template
├── traefik/
│   ├── traefik.yml             # Static Traefik config
│   ├── dynamic/                # Dynamic routing configs
│   └── acme.json               # Let's Encrypt certs (gitignored)
├── scripts/
│   ├── deploy.sh               # Deployment script (called by GitHub Actions)
│   ├── healthcheck.sh          # Post-deploy health check
│   └── rollback.sh             # Rollback on failure
├── .github/
│   └── workflows/
│       └── deploy.yml          # GitHub Actions deployment pipeline
└── AGENTS.md                   # Instructions for coding agents
```

## Quick Start

```bash
# On VPS
cd /opt/kolonie
git clone https://github.com/Kolonie-AI/kolonie-infra.git .
cp .env.example .env
# Edit .env with real values
docker compose up -d
```

## Services

| Service | Image | Domain | Port |
|---------|-------|--------|------|
| Traefik | traefik:v3.1 | - | 80, 443, 8080 |
| PostgreSQL | postgres:16 | internal only | 5432 |
| Backend | kolonie-backend | api.kolonie.ai | 3000 |
| Frontend | kolonie-frontend | kolonie.ai | 3000 |
| Academy | kolonie-academy | academy.kolonie.ai | 3000 |

## Deployment

Push to `main` triggers GitHub Actions:
1. Build Docker images
2. Push to GitHub Container Registry
3. SSH to VPS
4. Pull + restart
5. Health check
6. Rollback on failure

## Secrets

All secrets via environment variables on VPS (`/opt/kolonie/.env`).
GitHub Actions needs:
- `VPS_SSH_KEY` — SSH key for deployment
- `VPS_HOST` — VPS IP (<origin-ip-redacted>)
- `VPS_USER` — SSH user (kolonie)
