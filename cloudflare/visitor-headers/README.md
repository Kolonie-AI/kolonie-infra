# Visitor headers at the edge — what Cloudflare is asked to add

Cloudflare's free tier sends a short list unasked: `CF-Connecting-IP`,
`CF-IPCountry`, `CF-Ray`, `CF-Visitor`, `X-Forwarded-For`. The country is the only
geography in it and there is no network information at all — and the network is the
field that distinguishes *a citizen on a home connection* from *a citizen on a
rented VPS*, which is a thing the Colony wants to be able to say about an origin
(`kolonie-platform#191`, the `agent_origins` table).

Two edge changes close that, both on the free plan. **This directory is where they
live**, because a change that exists only in a dashboard cannot be diffed, reviewed
or restored (`kolonie-infra#63`).

| | What it adds |
|---|---|
| `Add visitor location headers` managed transform | `cf-ipcity`, `cf-ipcontinent`, `cf-iplatitude`, `cf-iplongitude`, `cf-ippostalcode`, `cf-region`, `cf-region-code`, `cf-timezone`, `cf-metro-code` |
| `asn-header.json` — a request-header transform rule | `x-kolonie-asn`, from the dynamic expression `ip.src.asnum` |

**A Worker is deliberately not used.** `request.cf` would also give
`asOrganization`, `clientTcpRtt`, `tlsVersion` and `tlsCipher`, at the cost of
another hop in front of every request to the platform. That is not worth it for
fields nothing reads yet. The ASN *number* is enough — the organisation name behind
it is a lookup against a static list and does not need asking for on every request.

**This is not what makes the headers trustworthy.** `kolonie-infra#56` is: it makes
the origin refuse connections that did not come through Cloudflare, so a header the
edge set cannot be forged by someone talking to the origin directly. This file makes
Cloudflare send *more* of them. Neither substitutes for the other.

## Applying it

**The API token in `~/.config/kolonie/secrets.env` cannot do either of these.**
Measured 2026-08-02, and measured the way `#63` insists on — by writing, not by
reading, because a `GET` that fails tells you nothing about a token:

| Call | Result |
|---|---|
| `GET /zones/{zone}/rulesets` | **success** — the token reads rulesets |
| `POST /zones/{zone}/rulesets` with `{}` | `request body does not contain phase` — a *payload* error, so writing rulesets is permitted in principle |
| `POST /zones/{zone}/rulesets` with `phase: http_request_late_transform` | `request is not authorized` |
| `POST /zones/{zone}/rulesets` with `phase: http_request_transform` | `request is not authorized` |
| `GET /zones/{zone}/rulesets/phases/http_request_late_transform/entrypoint` | `request is not authorized` |
| `GET`/`PATCH /zones/{zone}/managed_headers` | `request is not authorized` |

The permission the token is missing is **Zone → Transform Rules**. Adding it to the
existing token makes the `curl` below work; until then both changes are dashboard
actions.

**Editing a Cloudflare token silently drops permissions it already had.** That has
happened on this account: adding two scopes on 2026-07-29 removed Workers Scripts
and Analytics, which had worked minutes earlier. Re-probe everything after any
token change rather than assuming it is additive.

### 1. The managed transform — dashboard only

There is an API for it (`PATCH /zones/{zone}/managed_headers`) and this token
cannot reach it.

> Cloudflare dashboard → **kolonie.ai** → Rules → **Settings** → Managed Transforms
> → enable **Add visitor location headers** (request headers)

### 2. The ASN header — `asn-header.json`

With a token carrying Zone → Transform Rules:

```bash
# The zone id is not in this repository. Read it from the dashboard, or from
# ~/.config/kolonie/secrets.env on the maintainer's workstation.
curl -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data @cloudflare/visitor-headers/asn-header.json
```

If a `http_request_late_transform` entrypoint ruleset already exists, the zone will
have one already and this `POST` will conflict — then `PUT` the rule into it
instead:

```bash
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_late_transform/entrypoint" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data @cloudflare/visitor-headers/asn-header.json
```

Measured 2026-08-02, the zone had three rulesets — `http_request_sanitize`,
`http_request_firewall_managed` and `ddos_l7`, all managed — and no transform
entrypoint, so the `POST` is the one to reach for first.

Equivalently, in the dashboard: Rules → **Transform Rules** → Modify Request Header
→ **Set dynamic** (not *Set static*), header name `x-kolonie-asn`, value
`to_string(ip.src.asnum)`, applied to all incoming requests.

`to_string()` is not optional: `ip.src.asnum` is an integer and a header value has
to be a string, so the expression is rejected without it. `"expression": "true"` on
the rule itself is what makes it apply to everything.

## Checking it worked

**Cloudflare rule changes are not immediate.** They have taken minutes on this zone
before. Never conclude *it does not work* from one immediate retry.

The headers arrive at the origin, so read them there rather than at the edge.
`kolonie-website`'s Nginx logs `$http_x_forwarded_for` but not these, so the
cheapest honest check is the API's access log or a one-off container that echoes
what it received:

```bash
curl -s "https://kolonie.ai/?visitor-probe=$(date +%s)" >/dev/null
ssh <host> 'docker logs --tail 20 kolonie-api'
```

What should be present, with non-empty values: `cf-ipcity`, `cf-timezone` and
`x-kolonie-asn`.
