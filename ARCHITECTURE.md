# Architecture Decisions

This document records the infrastructure architecture decisions, the reasoning behind them, and their trade-offs.

## Decision Log

| Date | Decision | Status |
|------|----------|--------|
| 2026-07-25 | Single VPS for MVP | Active |
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
- Cloudflare Workers (not needed, the API handles logic)
- Cloudflare Pages (website deployed as a Docker container behind Traefik)
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

## Loki (not a hosted log service, and no Grafana)

Decided 2026-08-04, `kolonie-infra#68`. Loki and Promtail run beside the other
containers; `logs.kolonie.ai` is the read API, behind a token.

### Why
- **The requirement is that an agent can ask.** A hosted service means a web UI
  and a per-seat login; Loki is an HTTP API, so anything that can `curl` can
  answer *"did the triage runner error yesterday"* — including the daily Watch
  Agent in `kolonie-docs#133`.
- **No Grafana.** LogQL over HTTP is the interface. Grafana is the dashboard
  nobody opens and the component that turns a two-container addition into
  something to maintain. It can be added later against a Loki that has the data.
- **Promtail reads Docker's log files, never the socket.** A container with the
  Docker socket has root on the host. The service name reaches Promtail through
  the `x-logging` anchor instead, which names `com.docker.compose.service` as a
  json-file log label.
- **Labels are `service` and `level` only.** Anything per-request, per-agent or
  per-container belongs inside the JSON line, where `| json` finds it at query
  time and costs no index. Cardinality is how a Loki install dies.

### The split, and it is the thing to read before believing a green Loki

**Loki answers what broke *inside* the applications. It cannot answer whether
the host is alive** — it runs on the box it observes, so if the box goes, the
evidence goes with it. A silent VPS and a quiet week look identical from here.

That second question belongs to `kolonie-infra#69`: a check that runs off this
host and off GitHub Actions, asking the five `/health` endpoints from outside.
Reading a healthy Loki as a healthy host is the specific mistake this paragraph
exists to prevent.

| Question | Where it is answered |
|---|---|
| Did a service error, and what did it say? | Loki, `logs.kolonie.ai` |
| Has a service stopped logging entirely? | Loki, via `kolonie-docs#133`'s silent-service check |
| Is the host up at all? Is TLS about to expire? | The external check, `kolonie-infra#69` |
| Is a container unhealthy right now? | `health-watch.yml`, and Docker's own health state |

## Open Questions

- ~~**Prisma vs Drizzle?**~~ Decided 2026-07-27: Drizzle. Plain-SQL migrations are auditable, which matters under a double-entry ledger. See kolonie-docs/ARCHITECTURE.md.
- **Container registry?** GitHub Container Registry (ghcr.io) is free and integrated.
- ~~**Log aggregation?**~~ Decided 2026-08-04: Loki and Promtail, no Grafana. See above and `kolonie-infra#68`.
- **Monitoring?** Health checks now, plus an external liveness check — `kolonie-infra#69`.
