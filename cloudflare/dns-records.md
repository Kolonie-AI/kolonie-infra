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
