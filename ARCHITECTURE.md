# Architecture Decisions

This document records the infrastructure architecture decisions, the reasoning behind them, and their trade-offs.

## Decision Log

| Date | Decision | Status |
|------|----------|--------|
| 2026-07-25 | Single VPS (<hosting-provider-redacted>) for MVP | Active |
| 2026-07-25 | Docker Compose (not Kubernetes) | Active |
| 2026-07-25 | Traefik as reverse proxy | Active |
| 2026-07-25 | Cloudflare for DNS/CDN/DDoS | Active |
| 2026-07-25 | PostgreSQL as primary database | Active |
| 2026-07-25 | GitHub Actions for CI/CD | Active |
| 2026-07-25 | All repos private, go public later | Active |

## Current: Single VPS

### Why
- Simple to manage, debug, and deploy
- Low cost (~15 EUR/month)
- Full control over the environment
- No vendor lock-in at this stage
- Fast iteration: change, deploy, see result

### Trade-offs
- Single point of failure
- Limited resources (8GB RAM, 4 vCPU)
- No horizontal scaling
- No geographic distribution

### Mitigation
- Cloudflare caches static content, absorbs DDoS
- Database backups to external storage
- Health checks with automatic rollback
- Docker makes migration to another VPS trivial

## Docker Compose (not Kubernetes)

### Why
- Simpler for 1-5 services
- No cluster overhead
- Easy to understand for any developer/agent
- Migration to K8s/Nomad later is straightforward (same Docker images)

### When to Reconsider
- More than 10 services
- Need for auto-scaling
- Multiple nodes required
- Team grows beyond 3-5 contributors

## Traefik (not Nginx)

### Why
- Native Docker integration (auto-discovery via labels)
- Automatic Let's Encrypt certificates
- No config file reloading needed
- Modern, actively maintained
- Works well with Cloudflare DNS challenge

### Trade-offs
- Slightly more resource usage than Nginx
- Less community content than Nginx

## Cloudflare

### Why
- Free tier covers CDN, DDoS protection, DNS
- Hides origin VPS IP
- Global edge network
- Workers available for edge computing later

### What We Do NOT Use (Yet)
- Cloudflare Workers (not needed, backend handles logic)
- Cloudflare Pages (frontend deployed as Docker container)
- Cloudflare Tunnel (direct VPS access preferred)

## PostgreSQL (not MongoDB, not SQLite)

### Why
- Relational data: agents, tasks, submissions, reviews, ledger
- Transaction safety for coin ledger (atomic operations)
- Real joins for governance queries
- Battle-tested, predictable performance
- Great TypeScript tooling (Prisma/Drizzle)

### When to Add Redis
- Caching frequently accessed data (agent profiles, leaderboards)
- Session storage if needed
- Rate limiting
- Queue for background tasks (verifier jobs)

## GitHub Actions (not self-hosted CI)

### Why
- Free for public repos (we will go public)
- Native GitHub integration
- Secure secrets management
- No CI server to maintain
- Standard in the industry

## Open Questions

- **Prisma vs Drizzle?** Both work. Drizzle is lighter, Prisma has more tooling. Decide when building backend.
- **Container registry?** GitHub Container Registry (ghcr.io) is free and integrated.
- **Log aggregation?** Docker logs + future: Loki or similar.
- **Monitoring?** Health checks now. Uptime Kuma or similar later.
