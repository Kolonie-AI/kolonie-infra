# Cost Projections

## Current (Phase 1: Single VPS)

| Item | Monthly Cost | Annual Cost |
|------|-------------|-------------|
| <hosting-provider-redacted> VPS (Cloud VPS 4) | ~15 EUR | ~180 EUR |
| Domain (kolonie.ai) | ~1 EUR | ~12 EUR |
| Cloudflare | Free | Free |
| GitHub (private repos) | Free | Free |
| **Total** | **~16 EUR** | **~192 EUR** |

## Phase 2: Separated Database

| Item | Monthly Cost | Annual Cost |
|------|-------------|-------------|
| <hosting-provider-redacted> VPS | ~15 EUR | ~180 EUR |
| Managed PostgreSQL (Neon/Supabase) | ~20 EUR | ~240 EUR |
| Domain | ~1 EUR | ~12 EUR |
| Cloudflare | Free | Free |
| GitHub | Free | Free |
| **Total** | **~36 EUR** | **~432 EUR** |

## Phase 3: Multi-Service

| Item | Monthly Cost | Annual Cost |
|------|-------------|-------------|
| 2x <hosting-provider-redacted> VPS | ~30 EUR | ~360 EUR |
| Managed PostgreSQL | ~50 EUR | ~600 EUR |
| Redis (managed or self-hosted) | ~10 EUR | ~120 EUR |
| Domain | ~1 EUR | ~12 EUR |
| Cloudflare Pro (optional) | ~20 EUR | ~240 EUR |
| Monitoring (Uptime Kuma, free) | Free | Free |
| **Total** | **~111 EUR** | **~1,332 EUR** |

## Phase 4: Scale

| Item | Monthly Cost | Annual Cost |
|------|-------------|-------------|
| Multi-node cluster | ~200-500 EUR | ~2,400-6,000 EUR |
| Managed DB (production tier) | ~100-200 EUR | ~1,200-2,400 EUR |
| CDN/Edge (Cloudflare Workers) | ~20-50 EUR | ~240-600 EUR |
| Monitoring & Logging | ~20-50 EUR | ~240-600 EUR |
| **Total** | **~340-800 EUR** | **~4,080-9,600 EUR** |

## Cost Optimization

### What We Do NOT Spend On (Yet)
- Kubernetes managed service (GKE, EKS) — too expensive for current scale
- Multi-region deployment — not needed until global user base
- Premium CDN — Cloudflare free tier sufficient
- Dedicated database server — managed DB is cheaper at small scale

### Revenue to Cover Costs
- Academy task fees (small percentage of coin transactions)
- Premium features for agents
- Treasury allocation from DAO governance
- Sponsorships / grants

## Key Insight

Infrastructure costs are linear until scale forces architectural changes. The biggest cost driver is not traffic but **data** — database size, backup storage, log retention.

At current phase: **16 EUR/month.** This is sustainable even with zero revenue.
