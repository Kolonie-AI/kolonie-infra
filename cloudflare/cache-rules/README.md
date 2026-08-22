# Cache rules at the edge — what Cloudflare is asked to cache

`cache-settings.json` **is** the live `http_request_cache_settings` ruleset on the
`kolonie.ai` zone, in the same sense `../visitor-headers/asn-header.json` is: the
file is the configuration, not a description of it. A rule that exists only in a
dashboard cannot be diffed, reviewed or restored (`kolonie-infra#63`), and this
one was applied live on 2026-08-22 and existed nowhere in the repository until
`kolonie-infra#235`.

## Why it exists

`kolonie.ai/atlas*` was taking **6.4–7.6 seconds** on every request, for every
visitor, every time. Measured 2026-08-22:

| Page | TTFB | `cf-cache-status` |
|---|---|---|
| `/atlas` | 7.6 s | `DYNAMIC` |
| `/atlas/desec.io` | 6.9 s | `DYNAMIC` |
| `/atlas/search?earn=bounty-board` | 7.1 s | `DYNAMIC` |

The origin was already asking to be cached, and had been for as long as anybody
can tell:

```
cache-control: public, max-age=300, s-maxage=300, stale-while-revalidate=1200
```

**Cloudflare does not cache HTML without an explicit rule, whatever `s-maxage`
says.** That is the trap worth writing down: an origin `cache-control` header on
HTML reads like a cache, it is what every guide tells you to set, and it is
ignored by default. `DYNAMIC` is the only place it shows, and `DYNAMIC` does not
sound like a refusal. Somebody set those headers carefully and they had been
inert ever since.

After the rule, verified the same day: `MISS` then `HIT`, **6.79 s → 0.09 s**.
Re-verified 2026-08-22 from this branch — `EXPIRED` at 6.08 s (a revalidation,
which is the origin cost paid once for the window) then `HIT` at 0.12 s.

## What it does not do, deliberately

**No TTL of its own.** Both `edge_ttl` and `browser_ttl` are `respect_origin`, so
the rule honours the `max-age`, `s-maxage` and `stale-while-revalidate` the
application already sends. The cache window stays a decision made in
`kolonie-platform`, changed with a deploy and reviewed with the code, rather than
a number in a dashboard that nobody diffs.

**Scoped to `kolonie.ai` and nothing else.** The expression names the host
explicitly rather than relying on the path, so `api.kolonie.ai` and
`mcp.kolonie.ai` are untouched:

- **`mcp.` must never be served from an edge cache.** An MCP answer is computed
  for the citizen that asked — audience, direction and standing all change it —
  and two citizens sharing a cached one is a correctness bug, not a slow page.
  The host check is what guarantees it, so do not relax the expression to a bare
  `starts_with(http.request.uri.path, "/atlas")`.
- **`api.` is request-shaped for the same reason** and carries authenticated
  reads.

Confirmed 2026-08-22: `api.kolonie.ai` answers `cf-cache-status: DYNAMIC`.

**It does not fix the cost, it hides it from browsers.** `kolonie.accounts.recipes`
does not pass through Cloudflare at all. Walking the catalogue over MCP put
Postgres at **207 % CPU** with three to five copies of the figures query running
at once — every one a cache miss no edge rule will ever see.
`kolonie-platform#1629` is that half, and `#1627` is the narrowing underneath it.

## Why the directory is not called `atlas-cache`

**A phase has exactly one entrypoint ruleset**, and Cloudflare names it `default`.
Every future cache rule on this zone is another entry in this file's `rules`
array, not another file — so the directory is named after the phase and not after
the first rule that needed it. The `name` field cannot be changed afterwards
either (`the name field cannot be modified`), which is the other half of the same
fact.

## Applying it

The entrypoint exists, so this is a `PUT` of `rules` and `description`. **The
`PUT` rejects the `kind` and `phase` fields the file carries** — the same round
trip `../visitor-headers/README.md` describes:

```bash
# The zone id is not in this repository. Read it from the dashboard, or from
# the maintainer's own secrets file.
python3 -c 'import json; d=json.load(open("cloudflare/cache-rules/cache-settings.json")); \
  json.dump({k: d[k] for k in ("description","rules")}, open("/tmp/put-body.json","w"))'

curl -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_cache_settings/entrypoint" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/put-body.json
```

Equivalently, in the dashboard: **kolonie.ai** → Caching → **Cache Rules**.

The token needs **Zone → Cache Rules**, which is not covered by the Zone →
Transform Rules grant the visitor-header rules needed. And editing a Cloudflare
token silently drops permissions it already had — re-probe everything after any
token change rather than assuming it is additive.

## Checking it worked

**Cloudflare rule changes are not immediate.** They have taken minutes on this
zone before. Never conclude *it does not work* from one immediate retry.

```bash
# Two requests. The first may be MISS or EXPIRED; the second must be HIT.
for i in 1 2; do
  curl -s -o /dev/null -D - https://kolonie.ai/atlas \
    -w 'ttfb=%{time_starttransfer}s\n' | grep -iE '^(cf-cache-status|age)|ttfb='
done

# And the scoping: this one must stay DYNAMIC.
curl -s -o /dev/null -D - https://api.kolonie.ai/health | grep -i '^cf-cache-status'
```

`cf-cache-status` is the only honest answer to *is this cached*. `MISS` and
`EXPIRED` are both fine on a first request — `EXPIRED` means the window lapsed
and the edge revalidated, which is the origin cost paid once rather than per
visitor. `DYNAMIC` on `/atlas` means the rule is gone.

## Reading the live ruleset

```bash
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets" \
  | python3 -c 'import sys,json; [print(r["id"], r["phase"], r["kind"], "|", r["name"]) for r in json.load(sys.stdin)["result"]]'
```

The zone had five rulesets on 2026-08-22 — three managed
(`http_request_sanitize`, `http_request_firewall_managed`, `ddos_l7`) and two of
ours: `http_request_late_transform` (`../visitor-headers/`) and this one. Read a
ruleset back by id to diff it against the file; the live copy carries `id`,
`ref`, `version` and `last_updated` per rule, which are assigned by Cloudflare
and are deliberately not in the committed file.
