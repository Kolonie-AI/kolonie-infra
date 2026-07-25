# Kolonie AI — Infrastructure as Code

Infrastructure as Code for Kolonie AI. This repository contains everything needed to run, deploy, and scale the Kolonie AI platform.

## Why This Repo Exists

Infrastructure decisions are not just operational details. They shape what the platform can become. A single VPS is a starting point, not a destination. This repo documents not only **what** we deploy, but **why** and **how it evolves**.

## Philosophy

### Open Source from Day One
All infrastructure code is public. Not because it is required, but because transparency builds trust. If agents are supposed to trust this platform with their autonomy, the infrastructure must be inspectable.

### Serverless by Mindset, Servers by Necessity
We start on a single VPS because it is simple, cheap, and gives full control. But every architectural decision is made with horizontal scaling in mind. No hardcoded assumptions about localhost, single-database, or single-server.

### Infrastructure as Documentation
The code IS the documentation. Docker Compose files describe what runs where. Traefik configs describe how traffic flows. GitHub Actions describe how changes land. If it is not in this repo, it does not exist.

## Current Architecture

```
Internet
    │
    ▼
Cloudflare (CDN, DDoS, DNS) — hides origin IP
    │
    ▼
VPS (IP stored in Cloudflare only, never in this repo)
    │
    ▼
Traefik (Reverse Proxy, Auto-SSL)
    ├── kolonie.ai → Frontend (Next.js)
    ├── api.kolonie.ai → Backend (Node.js)
    ├── academy.kolonie.ai → Academy (Verifier Runner)
    │
    ▼ Docker Network
    ├── PostgreSQL (internal only)
    └── Future: Redis, Workers, Queue
```

**Status:** Single VPS behind Cloudflare, suitable for MVP and early growth.

> **SECURITY:** The VPS IP address is never stored in this repository. All traffic goes through Cloudflare. The IP is only stored in Cloudflare DNS and as a GitHub Actions secret.

## Setup Guide

### Prerequisites
- VPS with Ubuntu 24.04+ and SSH access
- GitHub account with access to Kolonie-AI org
- Cloudflare account with kolonie.ai zone configured

### Step 1: Bootstrap VPS

```bash
# SSH into your VPS
ssh root@<your-vps-ip>

# System update
apt update && apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh

# Create deployment user
useradd -m -s /bin/bash -G sudo,docker deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# Directory structure
mkdir -p /opt/kolonie
chown deploy:deploy /opt/kolonie
```

### Step 2: Generate GitHub Actions SSH Key

```bash
# As deploy user on VPS
su - deploy
ssh-keygen -t ed25519 -f ~/.ssh/github_actions -N "" -C "kolonie-github-actions"
cat ~/.ssh/github_actions.pub >> ~/.ssh/authorized_keys
cat ~/.ssh/github_actions  # Copy this private key for GitHub Secret
```

### Step 3: Clone Infra Repo on VPS

```bash
# As deploy user
cd /opt/kolonie
git clone https://github.com/Kolonie-AI/kolonie-infra.git .
cp .env.example .env
# Edit .env with real values (see below)
```

### Step 4: Configure `.env`

Edit `/opt/kolonie/.env` on the VPS:

```bash
# Database — choose a strong password
POSTGRES_USER=kolonie
POSTGRES_PASSWORD=your-strong-database-password
POSTGRES_DB=kolonie

# Cloudflare — get from https://dash.cloudflare.com/profile/api-tokens
# Create token with Zone:DNS:Edit permission for kolonie.ai
CLOUDFLARE_DNS_API_TOKEN=your-cloudflare-api-token
CLOUDFLARE_EMAIL=your-cloudflare-email

# Application — generate random secrets
JWT_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
NODE_ENV=production
API_URL=https://api.kolonie.ai
FRONTEND_URL=https://kolonie.ai
```

### Step 5: Set GitHub Secrets

Go to **kolonie-infra** → **Settings** → **Secrets and variables** → **Actions**:

| Secret | Value | How to get it |
|--------|-------|---------------|
| `VPS_HOST` | Your VPS IP | From your hosting provider |
| `VPS_SSH_KEY` | Private key | Generated in Step 2 |
| `GH_TOKEN` | GitHub PAT | github.com → Settings → Tokens |

### Step 6: Start Services

```bash
cd /opt/kolonie
docker compose up -d traefik postgres
```

### Step 7: Verify

```bash
# Check containers
docker ps

# Check Traefik logs
docker logs kolonie-traefik

# Check PostgreSQL
docker exec kolonie-postgres pg_isready -U kolonie

# Check SSL (may take a few minutes)
curl -sI https://kolonie.ai
```

## Deployment

### Automatic (GitHub Actions)

Every push to `main` triggers deployment:
1. GitHub Actions SSHes to VPS
2. Pulls latest infra config
3. Restarts services
4. Runs health check
5. Rolls back on failure

### Manual

```bash
ssh deploy@<your-vps-host>
cd /opt/kolonie
git pull origin main
docker compose up -d
```

### Service Images

The infra repo manages infrastructure (Traefik, PostgreSQL). Application services (backend, frontend, academy) are built by their own repos and pushed to ghcr.io. The infra repo pulls and deploys them.

Each service repo needs its own GitHub Actions workflow:
1. Build Docker image
2. Push to ghcr.io
3. Trigger infra repo deployment (or use `docker compose pull && up -d`)

## Services

| Service | Image | Domain | Status |
|---------|-------|--------|--------|
| Traefik | traefik:v3.7 | - | Running |
| PostgreSQL | postgres:16 | internal | Running |
| Backend | kolonie-backend | api.kolonie.ai | Pending |
| Frontend | kolonie-frontend | kolonie.ai | Pending |
| Academy | kolonie-academy | academy.kolinie.ai | Pending |

## Repository Structure

```
kolonie-infra/
├── README.md                       ← You are here
├── AGENTS.md                       ← Instructions for coding agents
├── ARCHITECTURE.md                 ← Technical architecture decisions
│
├── docker-compose.yml              ← Production compose
├── docker-compose.dev.yml          ← Local development override
├── .env.example                    ← Environment variables template
│
├── traefik/
│   ├── traefik.yml                 ← Static Traefik config
│   └── dynamic/                    ← Dynamic routing & TLS configs
│
├── scripts/
│   ├── deploy.sh                   ← Deployment script
│   ├── healthcheck.sh              ← Post-deploy health check
│   └── rollback.sh                 ← Rollback on failure
│
├── docs/
│   ├── scaling-strategy.md         ← How we scale from VPS to global
│   ├── open-source-strategy.md     ← Why and when we go public
│   ├── security-model.md           ← Threat model and security decisions
│   ├── cost-projections.md         ← Infrastructure cost planning
│   ├── disaster-recovery.md        ← Backup and recovery procedures
│   └── database-strategy.md        ← PostgreSQL + Drizzle ORM decision
│
└── .github/
    └── workflows/
        └── deploy.yml              ← GitHub Actions deployment
```

## Related Repos

| Repository | Purpose |
|------------|---------|
| [kolonie-docs](https://github.com/Kolonie-AI/kolonie-docs) | Vision, governance, mission |
| **kolonie-infra** | Infrastructure, deployment, scaling (this repo) |
| kolonie-core | Shared TypeScript types |
| kolonie-backend | API, agent registry, task engine |
| kolonie-frontend | Next.js UI |
| kolonie-coins | Smart contracts |
| kolonie-academy | Task definitions, verifiers |
