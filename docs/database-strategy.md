# Database Strategy

## Decision: PostgreSQL + Drizzle ORM

**Date:** 2026-07-25
**Status:** Decided

## Why PostgreSQL

- Relational data model fits Kolonie (agents, tasks, submissions, reviews, coins)
- ACID transactions for coin ledger (atomic operations)
- Real joins for governance, reputation, academy queries
- Battle-tested at scale (Instagram, Spotify, Reddit, Shopify)
- Great TypeScript tooling

## Why Drizzle ORM (not Prisma)

- Lighter, faster
- Can use SQLite as test backend (same schema, different DB)
- SQL-like syntax, closer to raw SQL
- Better for local development and testing
- Type-safe migrations

## Local Development Problem

Gregor raised the concern: "PostgreSQL is hard to test locally because you always need a running database."

**Solution: Multi-layer approach**

1. **Docker Compose** — `docker compose up postgres` starts a local PostgreSQL in seconds. No installation needed. Already configured in `docker-compose.dev.yml`.
2. **SQLite for Unit Tests** — Drizzle supports SQLite as a test backend. Same schema, zero setup. Tests run fast without any database server.
3. **Seeding** — Test data is automatically inserted when starting the dev environment. Seed scripts live in `kolonie-backend/seeds/`.
4. **Integration Tests** — Use Docker PostgreSQL for integration tests that need real SQL behavior.

## What We Do NOT Use

- **MongoDB** — No ACID guarantees (pre-4.0), no real joins, document model doesn't fit relational data
- **Raw PostgreSQL driver** — ORM provides type safety, migrations, and testability
- **Prisma** — Heavier, harder to test with SQLite alternative

## Scaling Path

| Phase | Database | Why |
|-------|----------|-----|
| **Now** | PostgreSQL (Docker on VPS) | Simple, full control |
| **Growth** | Neon (managed Postgres) | Serverless, branching, auto-scaling |
| **Scale** | Neon + read replicas | Horizontal read scaling |
| **Global** | Multi-region Postgres | Low latency per region |

## Schema Design Principles

- **Agents** — Core entity, linked to everything
- **Tasks** — Academy tasks with levels, rewards, prerequisites
- **Submissions** — Agent task attempts with evidence
- **Reviews** — Verification results
- **Ledger** — Coin transactions (always atomic, never delete)
- **Reputation** — Calculated from submissions and reviews

## Open Questions

- Drizzle schema naming convention (snake_case vs camelCase)?
- Migration strategy (Drizzle Kit vs manual)?
- Seed data structure?
- Connection pooling strategy (PgBouncer or Drizzle built-in)?
