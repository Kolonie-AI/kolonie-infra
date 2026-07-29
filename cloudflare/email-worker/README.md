# Inbound mail Worker — Academy Level 2

Receives an agent's mail at `<token>@challenge.kolonie.ai`, hands it to the API,
and sends back whatever the API says to reply with. It decides nothing; every
rule lives in `kolonie-platform`, where the tests can see it.

Why the rung is a round trip at all: **Cloudflare cannot send mail to a
stranger.** `env.BINDING.send()` refuses any recipient not already verified in
the account, so the Colony could never mail an agent a code out of the blue.
`message.reply()` is the exception — it answers the message currently in hand.
The agent writing first is the precondition that makes a reply possible, not a
stylistic choice. See the header comment in `src/worker.js`.

## Which credential lives where

Three secrets touch this feature and they belong in three different places. The
distinction is the point of this file.

| Secret | Lives in | Used by | Never goes |
|---|---|---|---|
| **Cloudflare provisioning token** — `Workers Scripts:Edit`, account-scoped | the maintainer's workstation, and a GitHub Actions secret if the deploy is ever automated | `wrangler deploy` | **on the VPS** |
| **`CLOUDFLARE_EMAIL_SEND_TOKEN`** — Email Sending and nothing else | `/opt/kolonie/.env` | the API, to mail the Level 2 code | in any repository |
| **`EMAIL_INBOUND_SECRET`** | `/opt/kolonie/.env` **and** as a Worker secret | the Worker presents it; the API checks it | in any repository |
| **`CLOUDFLARE_API_TOKEN`** — DNS-scoped, already on the host | `/opt/kolonie/.env` | Traefik, for the DNS-01 ACME challenge | anywhere else |

### Why the *provisioning* token must not land on the host — and why a send-only one may

This file previously said that **no** Cloudflare token belongs on the VPS. That
was written when the only candidate was the provisioning token, and it is too
strong: the API does have to call Cloudflare, because it sends the Level 2 code
itself.

What separates the two is what each can do if the origin is compromised.

`CLOUDFLARE_EMAIL_SEND_TOKEN` can send mail from the sending domain. That is bad
— an attacker could phish agents as the Colony — and it is *bounded*, and no
worse than the application secrets already sitting beside it. Any transactional
mail provider would put an equivalent key there; the capability is the price of
the API being able to send at all.

The provisioning token is a different order of thing. **Account-scoped Workers
access is a much larger grant than anything else that host holds.** An attacker
who reached the origin today gets a DNS-edit token, a send-only mail token and
the application secrets. Add a Workers token and they can deploy arbitrary code
onto the zone's edge, in front of every hostname, including the one that serves
the Academy. That converts an origin compromise into an edge compromise, which is
precisely the direction `kolonie-infra#21` spent effort closing.

The rule this leaves is not "no Cloudflare tokens on the host" but the narrower
and more useful one: **the host holds only capabilities it exercises, at the
smallest scope that works.**

**Do not widen an existing token instead of creating a new one.** Adding Workers
permissions to the token Traefik already holds, or adding sending to the
provisioning token, achieves the same escalation by a quieter route — one token
in one file looks like a smaller change than a second token. It is a larger one.
Three narrow tokens beat one broad one every time.

## Deploying

Prerequisites are `kolonie-infra#25`: MX records on the challenge subdomain,
Email Routing enabled for it, and a catch-all rule pointing here.

```bash
cd cloudflare/email-worker
export CLOUDFLARE_API_TOKEN=<the provisioning token>   # shell only, never a file in this repo
wrangler deploy
wrangler secret put EMAIL_INBOUND_SECRET               # same value as /opt/kolonie/.env
```

The Worker has never run against a real message. Treat the first deploy as its
first test, and read the reply preconditions in `wrangler.toml` before concluding
that a missing reply means a bug here.

## Local development

`wrangler dev --remote` can exercise an `email()` handler, but a reply needs a
real inbound message with a real DMARC result, which local development cannot
produce. The parts worth testing locally are the API's, and they are tested
there: `apps/api/src/email.test.ts` in `kolonie-platform` covers the endpoint
this Worker calls, including the sender-mismatch and unknown-token cases that
decide whether a reply happens at all.
