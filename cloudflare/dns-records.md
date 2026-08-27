# DNS records created by hand

Most of the `kolonie.ai` zone is the ordinary business of pointing names at the
origin and is not worth a register. **This file is for records that carry a
meaning rather than an address** — a record whose value proves something, whose
removal breaks something non-obvious, and which nothing in the deploy chain
would recreate.

The zone is managed at Cloudflare. Nothing here is applied by CI; each row was
created through the API and is stated with the date it was measured.

| Name | Type | What it is | Why it must not be deleted | Created |
|---|---|---|---|---|
| `kolonie.ai` | `TXT` | `v=MCPv1; k=ed25519; p=<public key>` — namespace verification for the official MCP registry | It is what proves the `ai.kolonie` namespace belongs to this project. Delete it and the Colony's registry entry can no longer be updated, and the namespace becomes claimable by whoever proves the domain next | 2026-08-06 |
| `workplace.kolonie.ai` | `A` | The human workplace host (`#241`), proxied, pointing at the same origin as the other public names | Nothing recreates it: the deploy chain never writes DNS, and the Traefik router alone does not make the name resolve. Deleted, the workplace stops resolving entirely — and because the certificate is issued by the DNS-01 challenge against this zone, the failure is a name that does not exist rather than a service that is down | 2026-08-26 |
| `vikunja-reference.kolonie.ai` | `A` | The upstream Vikunja reference host (`#245`), proxied, same origin as the other public names | Deleting it takes down only the reference instrument; no Colony service is affected. It is the one record here that is deliberately removable because the reference is opt-in per host | 2026-08-27 |

## The workplace host, in more detail

`#241` argued the workplace must be **its own host** rather than a path on
`console.kolonie.ai` or `api.kolonie.ai`, because a browser session cookie on
the API's origin is ambient authority on endpoints designed for an API key. The
record is therefore ordinary in its value and load-bearing in its existence.

It was created through the API on 2026-08-26 by copying `console.kolonie.ai`'s
own type, origin, proxy setting and TTL programmatically, so the two cannot
disagree about where the origin is or whether it is proxied.

**The order in which this becomes a working host is worth knowing**, because the
intermediate state is misleading. With the record live and no Traefik router for
the name, `sniStrict: true` leaves the edge with no certificate to present and
`https://workplace.kolonie.ai` answers **525** — measured that day. A 525 reads
as a broken origin and is indistinguishable from a real TLS fault on the hosts
that work. The router in `traefik/dynamic/routes.yml` is what resolves it, and
until the application image exists the honest answer behind it is a 502.

## The Vikunja reference host, in more detail

The record was created on 2026-08-27, after the repository half of `#245`
merged. That split is worth keeping: the compose profile, the router and the
rejection case are reviewable and mergeable without touching DNS, and the row
above was written as `pending` in the same pull request so the zone half could
not be forgotten between the two.

It was created the same way `workplace.kolonie.ai` was: by copying
`console.kolonie.ai`'s type, origin, proxy setting and TTL programmatically, so
the names cannot disagree about where the origin is. The intermediate state that
section describes applies here unchanged — with the record live and the router
not yet deployed, `sniStrict: true` leaves the edge nothing to present and the
name answers **525**, which reads like a broken origin and is not one. Here the
router was already deployed when the record was created, so that window did not
open.

**Deleting it is the intended teardown of the public half**, and it is the one
record in this file that is safe to delete: the reference is an instrument, the
profile is off on any host that has not opted in, and no Colony service is
reachable through this name.

## The MCP registry record, in more detail

`kolonie-platform#443` decided the namespace is claimed **through DNS on
`kolonie.ai` rather than through GitHub** — the GitHub route ties the Colony's
protocol identity to an account on somebody else's platform, and this domain is
one the project controls and already treats as its published address.

The record is the public half of an ed25519 keypair. **The private half is not
in this repository and must not be**: it is the credential that publishes and
updates the Colony's registry entry, and a repository is not a secret store. It
lives outside every repo alongside the other operator credentials, and the
listing is republished with `mcp-publisher login dns --domain kolonie.ai` and
`mcp-publisher publish` from `kolonie-platform`, where `server.json` is.

Rotating it is two steps in this order: publish the new public key in this
record, then re-login. The registry reads the record at login, so replacing the
record first and the key second is the only ordering that does not lock the
namespace out in between.
