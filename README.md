# Kolonie AI — Infrastructure as Code

Infrastructure as Code for Kolonie AI. This repository contains everything needed to run, deploy, and scale the Kolonie AI platform.

Cross-project status is in [`kolonie-docs/state/STATUS.md`](https://github.com/Kolonie-AI/kolonie-docs/blob/main/state/STATUS.md).

## Current State

**All five services are running and healthy on the VPS.** The deploy chain is
connected end to end: a merge in `kolonie-platform` or `kolonie-website` builds
the image and calls the reusable deploy workflow in this repository.

```
kolonie-traefik              healthy   (v3.7, Reverse Proxy, Let's Encrypt via Cloudflare DNS Challenge)
kolonie-postgres             healthy   (PostgreSQL 16-alpine)
kolonie-api                  healthy   (api + academy + mcp + challenge)
kolonie-verifier-runner      healthy   (no ingress — outbound only)
kolonie-website              healthy   (Astro + Starlight)
```

Traefik Dashboard is disabled (`api.dashboard: false`).

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
    ├── kolonie.ai → website (static Astro)
    ├── www.kolonie.ai → redirect to apex
    ├── api.kolonie.ai → api (Node.js + MCP)
    ├── academy.kolonie.ai → api (academy endpoints)
    ├── mcp.kolonie.ai → api (MCP server — own router, same container)
    ├── challenge.kolonie.ai → api (Browser Capability Gate page — D-022)
    │
    ▼ Docker Network
    ├── verifier-runner (no ingress — outbound only)
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

### Step 1: SSH into VPS

```bash
ssh ubuntu@<your-vps-ip>
```

> **Note:** The VPS only accepts `ubuntu` as login user. `root` will be rejected.

### Step 2: System setup (already done)

```bash
# Docker is installed (v29.6.2)
# Docker Compose is installed (v5.3.1)
# /opt/kolonie exists with the repo cloned
# .env is configured
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
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token
CLOUDFLARE_EMAIL=your-cloudflare-email

# Application — generate random secrets
JWT_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
NODE_ENV=production
API_URL=https://api.kolonie.ai
WEBSITE_URL=https://kolonie.ai
```

This block is an excerpt and goes stale. `.env.example` is the list, and
`./scripts/env-drift.sh /opt/kolonie` is how you find out whether the host still
matches it — run it rather than reading two files side by side, which is how
`FRONTEND_URL` and `WEBSITE_URL` came to be two names for one address (#8).

### Step 3: GitHub Secrets

These are already set in kolonie-infra → Settings → Secrets:

| Secret | Description |
|--------|-------------|
| `VPS_HOST` | VPS IP (Cloudflare-proxied, never in repo) |
| `VPS_SSH_KEY` | SSH private key for `ubuntu` user |

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

A push to `main` triggers a deployment **unless it only touches documentation**
(#13). The filter is a `paths-ignore` list — Markdown, `docs/`, `state/`, the
issue templates — rather than a list of what does deploy. That direction is
deliberate: a change that is silently *not* deployed is much harder to notice
than one that is, so anything not provably inert still ships.

1. GitHub Actions SSHes to the VPS
2. Pulls the latest infra config
3. `scripts/deploy.sh`: pull → pin → migrate → seed → `up -d`
4. Runs the health check
5. Rolls back to the last build that passed one, on failure

### Deploying a specific build

`deploy.yml` takes a `service` and a `version`. `service` is `all`, one service,
or a comma-separated list; `version` is applied to every service named, and to
nothing else.

```bash
gh workflow run deploy.yml -R Kolonie-AI/kolonie-infra \
  -f service=api -f version=<sha>

# One commit that rebuilt two images — deployed in one run, api first.
gh workflow run deploy.yml -R Kolonie-AI/kolonie-infra \
  -f service=api,verifier-runner -f version=<sha>
```

**A list is one deploy, not several, and that is the point** (#31). A commit
touching `packages/core` or `packages/db` rebuilds every image, and while each
build called this workflow separately, one of those calls was evicted from the
concurrency queue every time — GitHub allows one pending run per group, so a
third arrival replaces the one already waiting. Three consecutive pushes on
2026-07-30 each dropped the **api** deploy: the largest image, so reliably second
in the queue, and the only one carrying `migrate()` and the Academy seed.

The order within a list is fixed by `scripts/deploy-set.sh` and not by the
caller: api, verifier-runner, moderation-runner, website. The api runs the
migrations out of its own image, so a runner started ahead of it is a runner
reading a schema that has not moved. If a deploy in the sequence fails and rolls
back, the ones after it do not run — that is the ordering doing its job, not a
limitation of it.

Sharing one `version` across a list is safe for the reason a list exists at all:
a list only ever comes from one commit's builds. Across *different* callers the
images share no version, which is why the input is per-deploy and not global.

`version` defaults to `latest`, which is what a push to this repository means:
re-deploy whatever is current. Naming a tag is how a deploy becomes a function
of a commit rather than of whatever finished building most recently.

A `workflow_dispatch` always deploys, whatever the path filter says.

### Manual Deploy

```bash
ssh ubuntu@<vps-host>
cd /opt/kolonie
git pull origin main
docker compose up -d
```

### Service Images

The infra repo manages infrastructure (Traefik, PostgreSQL). Application services (`api`, `verifier-runner`, `website`) are built by `kolonie-platform` and `kolonie-website` and pushed to `ghcr.io`.

**How deployment works:**
1. Push to `main` triggers GitHub Actions
2. Actions SSHs to VPS as `ubuntu`
3. Runs `git pull origin main` in `/opt/kolonie`
4. Runs `scripts/deploy.sh`: pull → **pin** → migrate → seed → `up -d` → health check
5. Runs `scripts/healthcheck.sh` which checks container health via Docker inspect

**Nothing is ever run from a mutable tag.** `deploy.sh` pulls `:latest`, resolves
it to the digest the registry just served, and starts the containers from that
digest — so the build that is inspected is the build that runs, and it cannot
change underneath the deploy. After the health check passes, those digests are
written to `state/deployed.env`; that file is what `rollback()` returns to, and
it is the only place the host records which build is serving (#12).

**`--remove-orphans` is conditional.** It is passed only on a full deploy where
every application image was reachable. That flag deletes every container absent
from the compose view it is given, and two things make that view incomplete: a
single-service deploy, and an image the deploying token could not read. On
2026-07-28 an incomplete view took three healthy services down in response to one
container that was in fact serving every request; withholding the flag leaves a
stale container instead, which is visible and fixable.

**To add a new service:**
1. Build image in its own repo → push to `ghcr.io/kolonie-ai/<service>:latest`
2. Add service definition to `docker-compose.yml` (with `profiles: [full]` if optional).
   Write the image as `${SERVICE_IMAGE:-ghcr.io/kolonie-ai/<service>:latest}` and pin
   it in `deploy.sh`, or it will be the one service nobody can roll back
3. Next infra deploy will pick it up automatically

### The host mirrors origin — it does not merge

The deploy runs `git fetch` + `git reset --hard origin/main` in `/opt/kolonie`,
and the SSH script runs under `set -euo pipefail`. Both are the fix for one
incident on 2026-07-29: after this repository's history was rewritten, `git pull`
failed with *"Need to specify how to reconcile divergent branches"*, the script
carried on regardless, and three deploys ran against infrastructure config frozen
at the pre-rewrite commit while reporting success.

A deploy target has no commits of its own to preserve, so merging is never the
right answer. Fetch-and-reset cannot diverge — a history rewrite, a force-push or
accidental local drift all resolve the same way.

### Only the edge reaches the origin

`scripts/origin-firewall.sh` restricts ports 80 and 443 on the WAN interface to
Cloudflare's published ranges, fetched at apply time from
`https://www.cloudflare.com/ips-v4` and `ips-v6` — never from a list pasted into
the repository, because Cloudflare adds ranges and a stale allowlist refuses a
legitimate edge node with nothing in any log here to explain it. A systemd timer
re-runs it daily; the unit re-runs it after every boot and after Docker starts.

```bash
sudo /opt/kolonie/scripts/origin-firewall.sh status
```

**The rules live in `DOCKER-USER`, and that is the whole trick.** ufw was already
active on this host with `deny (incoming)` — and 80/443 answered the entire
internet regardless, because Docker publishes a port with its own DNAT rule and
the packet never traverses ufw's INPUT chain. `ufw deny 80` would have looked
like a fix and changed nothing. `DOCKER-USER` is the chain Docker guarantees it
will not overwrite, consulted before its own forwarding rules.

ufw does carry ALLOW rules for 80 and 443, and they are inert. They have been
there since the host was built and deleting them would change nothing, because
no packet bound for a published port ever reaches the chain they sit in. Read
`ufw status` accordingly: the ports it genuinely governs are 22 and the inbound
default-deny.

The match is confined to the WAN interface. `DOCKER-USER` also carries
container-to-container traffic and Traefik reaches the website container on port
80 — an un-scoped rule would drop exactly that and 502 the site from the inside.

What this proves is *a* Cloudflare edge, not *this zone's* edge: any Cloudflare
customer can point a hostname at this address. Closing that needs authenticated
origin pull, which needs a zone setting — see #21.

### What the operating system enforces

`scripts/host-hardening.sh` owns the SSH authentication policy and the fail2ban
jail, and it checks ufw and `unattended-upgrades` without owning them.

```bash
sudo /opt/kolonie/scripts/host-hardening.sh verify   # non-zero on drift
sudo /opt/kolonie/scripts/host-hardening.sh apply
```

`verify` runs on every deploy as a `continue-on-error` step — drift is worth
seeing every time and never worth blocking a deploy for, not least because a
deploy is how a drifted host gets repaired.

**Why the SSH policy needs two files, and why they are numbered.** sshd uses the
**first** value it obtains for a keyword, so among the drop-ins in
`/etc/ssh/sshd_config.d/` the lowest-numbered file wins — and cloud-init writes
`50-cloud-init.conf` on its own schedule. The global `PasswordAuthentication no`
therefore sits in `10-kolonie-auth.conf`, ahead of anything cloud-init has to
say.

The `Match` block sits at the other end, in `99-kolonie-breakglass.conf`. A
`Match` runs until the next `Match` or the end of the file, and `Include` splices
files inline, so a `Match` left open at the end of a low-numbered file would
swallow whatever is included after it into a conditional block. At the true end
of the parse there is nothing left to capture.

**One account keeps password login on purpose.** It holds nothing, has no keys,
and exists so that a lost or corrupted deploy key does not leave the provider's
console as the only way back in. What makes that safe is the fail2ban policy
rather than the account, which is why the jail's numbers are pinned in
`/etc/fail2ban/jail.d/kolonie.conf` rather than inherited from the package. The
deploy account is `L` in `/etc/shadow` and has no password to offer; `verify`
fails if it ever acquires one.

The argument for both — why a claim here has to be executable, and what the
break-glass account does and does not defend against — is in `state/decisions.md`
in kolonie-docs, under *"Why a security claim has to be executable"* and *"Why
one account still has a password"*.

## Services

| Service | Image | Domain | Status |
|---------|-------|--------|--------|
| Traefik | traefik:v3.7 | - | Running |
| PostgreSQL | postgres:16 | internal | Running |
| api | kolonie-api | api.kolonie.ai, academy.kolonie.ai, mcp.kolonie.ai, challenge.kolonie.ai | Running |
| verifier-runner | kolonie-verifier-runner | none (outbound only) | Running |
| website | kolonie-website | kolonie.ai | Running |

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
│   ├── rollback.sh                 ← Return to the last build that passed a health check
│   ├── backup.sh                   ← Daily pg_dump into an off-host restic repository
│   ├── rehearse-deploy.sh          ← Run deploy.sh against a stub docker; no VPS needed
│   └── rehearse-backup.sh          ← Run backup.sh against a stub docker and restic
│
├── docs/
│   ├── scaling-strategy.md         ← How we scale from VPS to global
│   ├── open-source-strategy.md     ← Why and when we go public
│   ├── security-model.md           ← Threat model and security decisions
│   ├── cost-projections.md         ← Infrastructure cost planning
│   ├── disaster-recovery.md        ← Backup and recovery procedures
│   └── database-strategy.md        ← PostgreSQL + Drizzle ORM decision
│
├── systemd/                        ← Host units: origin firewall, backup timer
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
| kolonie-platform | Monorepo: domain model, API, MCP, task engine, verifiers, ledger |
| kolonie-website | Public website + docs (Astro + Starlight) |
| kolonie-skills-openclaw | OpenClaw skill (immigration portal) |
