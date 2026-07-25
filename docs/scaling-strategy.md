# Scaling Strategy

## Overview

Kolonie AI starts on a single VPS. This is intentional, not a limitation. The architecture is designed so that every scaling step is an incremental change, not a rewrite.

## Phase 1: Single VPS (Now)

**Architecture:** Docker Compose on VPS
**Capacity:** ~1,000 concurrent users
**Cost:** ~15 EUR/month

```
VPS (8GB RAM, 4 vCPU)
├── Traefik
├── PostgreSQL (Docker volume)
├── Backend (Node.js)
├── Frontend (Next.js)
└── Academy (Verifier Runner)
```

### What Works
- Simple deployment (git push → GitHub Actions → SSH → restart)
- Easy debugging (all logs on one machine)
- Fast iteration
- Database and application on same host (low latency)

### What Breaks
- Database fills disk
- Traffic spike overwhelms single CPU
- VPS goes down = everything down
- Cannot scale individual services

## Phase 2: Separated Database (~1k-50k users)

**Trigger:** Database load exceeds 50% of VPS resources, or disk space becomes critical.

**Change:** Move PostgreSQL to managed database service.

**Options:**
| Provider | Cost | Why |
|----------|------|-----|
| Neon | Free tier → $19/mo | Serverless Postgres, branching, great for dev |
| Supabase | Free tier → $25/mo | Postgres + auth + storage |
| Railway | ~$10/mo | Simple, Docker-friendly |
| Self-hosted on 2nd VPS | ~15/mo | Full control |

**Architecture after:**
```
VPS (App Server)          Managed PostgreSQL
├── Traefik               ├── Primary
├── Backend               ├── Read Replica (optional)
├── Frontend              └── Automated Backups
└── Academy
```

### Migration Steps
1. Set up managed PostgreSQL
2. Run migration scripts
3. Update DATABASE_URL in .env
4. docker compose restart
5. Verify, done

**Downtime:** ~5 minutes with proper planning.

## Phase 3: Multi-Service (~50k-500k users)

**Trigger:** Single VPS cannot handle application load.

**Options:**

### Option A: Vertical Scaling (Simpler)
Upgrade VPS: 16GB RAM → 32GB → 64GB. Same architecture, bigger machine.

- **Pro:** Zero architecture changes
- **Con:** Ceiling exists, single point of failure remains

### Option B: Docker Swarm (Medium Complexity)
Multiple VPS nodes, Docker Swarm orchestration.

```
Manager Node (Traefik, orchestration)
├── Worker Node 1 (Backend, Academy)
├── Worker Node 2 (Backend, Academy)
└── Worker Node 3 (Frontend, static)
```

- **Pro:** Horizontal scaling, built into Docker
- **Con:** More complex networking, state management

### Option C: Kubernetes (High Complexity)
Full orchestration with auto-scaling, rolling updates, self-healing.

- **Pro:** Industry standard, maximum flexibility
- **Con:** Operational overhead, steep learning curve

**Recommendation:** Option A (vertical) until it clearly does not work. Then Option B (Docker Swarm). Kubernetes only if there is a real need and someone to operate it.

## Phase 4: Global Distribution (~500k+ users)

**Trigger:** Users across multiple continents, latency becomes visible.

**Changes:**
- Multi-region deployment (EU + US + Asia)
- CDN for static assets (Cloudflare already handles this)
- Database read replicas per region
- Edge caching for API responses
- Geographic routing via Cloudflare

**This phase is theoretical.** By the time Kolonie AI needs this, the platform will have the resources and team to handle it.

## Key Principles

1. **No premature optimization.** Single VPS until it hurts.
2. **Every step is incremental.** No big-bang rewrites.
3. **Docker everywhere.** Same images run on VPS, Swarm, or K8s.
4. **Database is the bottleneck.** Scale it first.
5. **Cloudflare absorbs traffic.** CDN + DDoS protection reduces origin load.
6. **Monitoring before scaling.** You cannot scale what you cannot measure.

## Cost Projections

See [cost-projections.md](cost-projections.md) for detailed cost planning.
