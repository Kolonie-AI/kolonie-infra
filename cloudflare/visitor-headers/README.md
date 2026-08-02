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
| `Add visitor location headers` managed transform | `cf-ipcity`, `cf-ipcontinent`, `cf-iplatitude`, `cf-iplongitude`, `cf-postal-code`, `cf-region`, `cf-region-code`, `cf-timezone` |
| `asn-header.json` — a request-header transform rule | `x-kolonie-asn`, from the dynamic expression `ip.src.asnum` |

**Two of those names are not what Cloudflare's own list says**, measured at the
origin on 2026-08-02 rather than copied from the documentation:

- the postal code arrives as **`cf-postal-code`**, not `cf-ippostalcode` — no `ip`
  in it, and hyphenated where its neighbours are not
- **`cf-metro-code` does not arrive at all.** It is a US metro/DMA code and is sent
  for US visitors only, so a European request shows the set one header short

Anything reading these should key on what arrives, not on the list. That is the
whole reason the observed capture is pasted further down instead of a promise.

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

**Both are applied. The token can do both, and needed two separate grants to get
there** — which is the part worth keeping, because the obvious guess is that one
permission covers "transforms".

Measured 2026-08-02 the way `#63` insists on — by writing, not by reading, because
a `GET` that fails tells you nothing about a token. Starting state:

| Call | Result |
|---|---|
| `GET /zones/{zone}/rulesets` | **success** — the token reads rulesets |
| `POST /zones/{zone}/rulesets` with `{}` | `request body does not contain phase` — a *payload* error, so writing rulesets is permitted in principle |
| `POST /zones/{zone}/rulesets` with `phase: http_request_late_transform` | `request is not authorized` |
| `POST /zones/{zone}/rulesets` with `phase: http_request_transform` | `request is not authorized` |
| `GET /zones/{zone}/rulesets/phases/http_request_late_transform/entrypoint` | `request is not authorized` |
| `GET`/`PATCH /zones/{zone}/managed_headers` | `request is not authorized` |

**Zone → Transform Rules was added to the token that afternoon, and re-probed.**
The ASN rule is applied and live; the managed transform is not, because it needs a
*different* permission:

| Call, after Transform Rules was granted | Result |
|---|---|
| `GET /zones/{zone}/rulesets/phases/http_request_late_transform/entrypoint` | `10003 could not find entrypoint ruleset in the http_request_late_transform phase` — a **state** error, so the permission is present and the zone simply had no such ruleset |
| `POST /zones/{zone}/rulesets` with the transform phase | **success** |
| `PATCH /zones/{zone}/managed_headers` with a real body | `request is not authorized` — **still** |

**Then Zone → Managed Headers was added as well**, and the endpoint answered:

| Call, after Managed Headers was granted | Result |
|---|---|
| `GET /zones/{zone}/managed_headers` | **success** — six managed transforms listed, `add_visitor_location_headers` among them, **all `enabled: false`** |
| `PATCH /zones/{zone}/managed_headers` enabling it | **success**, read back `enabled: true` |

So the two halves of this issue sat behind two permissions, not one. Transform
Rules covers rulesets; the managed transforms endpoint does not move with it. In
the token editor they are **Zone → Transform Rules** and **Zone → Managed
Headers**.

**The `GET` also settled a question worth not re-asking:** every managed transform
on this zone was off, including the response-side `add_security_headers`. The
Colony sends its security headers from Traefik instead (`#59`), from configuration
that lives in this repository and can be diffed. Two sources for one header set is
the failure mode `#59` exists to close, so **do not turn that one on** without
retiring the Traefik middleware in the same change.

**Editing a Cloudflare token silently drops permissions it already had.** That has
happened on this account: adding two scopes on 2026-07-29 removed Workers Scripts
and Analytics, which had worked minutes earlier. Re-probe everything after any
token change rather than assuming it is additive. Re-probed after this one — DNS,
rulesets and the zone read all still answer.

**Editing a Cloudflare token silently drops permissions it already had.** That has
happened on this account: adding two scopes on 2026-07-29 removed Workers Scripts
and Analytics, which had worked minutes earlier. Re-probe everything after any
token change rather than assuming it is additive.

### 1. The managed transform — **applied 2026-08-02**

```bash
curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/managed_headers" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data '{"managed_request_headers":[{"id":"add_visitor_location_headers","enabled":true}],"managed_response_headers":[]}'
```

**Send `managed_response_headers` as an empty array, not omitted**, and send only
the one request header you are changing — the endpoint merges rather than
replacing, so the other five keep their state. Read it back with a `GET`
afterwards; that is one call and it is the difference between "the API said
success" and "the setting is on".

Equivalently, in the dashboard: **kolonie.ai** → Rules → **Settings** → Managed
Transforms → enable **Add visitor location headers** (request headers).

### 2. The ASN header — **applied 2026-08-02**

The file in this directory is the live configuration, and it was applied verbatim:

```bash
# The zone id is not in this repository. Read it from the dashboard, or from
# ~/.config/kolonie/secrets.env on the maintainer's workstation.
curl -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data @cloudflare/visitor-headers/asn-header.json
```

Measured 2026-08-02, the zone had three rulesets — `http_request_sanitize`,
`http_request_firewall_managed` and `ddos_l7`, all managed — and no transform
entrypoint, so `POST` is the call. It is now four.

**If a `http_request_late_transform` entrypoint already exists**, `POST` conflicts
and the rules go in with `PUT` — but note two things that cost a round trip each
when this was first applied:

```bash
# PUT to a phase entrypoint takes `rules` (and `description`) and REJECTS the
# `kind` and `phase` fields the POST body carries:
#   invalid JSON: unknown field "kind"
python3 -c 'import json; d=json.load(open("cloudflare/visitor-headers/asn-header.json")); \
  json.dump({k: d[k] for k in ("name","description","rules")}, open("/tmp/put-body.json","w"))'

curl -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_late_transform/entrypoint" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/put-body.json
```

**And a ruleset's name cannot be changed afterwards** — `the name field cannot be
modified: got …, want …`. A ruleset created under a throwaway name keeps it until
somebody deletes and recreates it, which is what happened here: the permission
probe was a `POST` with `name: probe`, it succeeded the moment the permission
landed, and the zone briefly had a production ruleset called `probe`. **Probe with
a call that cannot create something**, or be ready to delete what the probe made.

Equivalently, in the dashboard: Rules → **Transform Rules** → Modify Request Header
→ **Set dynamic** (not *Set static*), header name `x-kolonie-asn`, value
`to_string(ip.src.asnum)`, applied to all incoming requests.

`to_string()` is not optional: `ip.src.asnum` is an integer and a header value has
to be a string, so the expression is rejected without it. `"expression": "true"` on
the rule itself is what makes it apply to everything.

## Checking it worked

**Cloudflare rule changes are not immediate.** They have taken minutes on this zone
before. Never conclude *it does not work* from one immediate retry.

The headers arrive at the origin, so read them there rather than at the edge — and
**nothing on the host logs them**. `kolonie-website`'s Nginx logs
`$http_x_forwarded_for` and no other header; `kolonie-api` logs one line at startup
and nothing per request; Traefik's access log carries no arbitrary request header
without a static-config change and a restart.

So the check that works is a brief packet capture of the plain-HTTP hop between
Traefik and a container, matched on a unique query string. It reads traffic and
changes nothing:

```bash
TS=$(date +%s)
ssh <host> "sudo -n timeout 20 tcpdump -i any -A -s0 -l 'tcp port 80' > /tmp/cap-$TS.txt 2>/dev/null &"
sleep 3
curl -s -o /dev/null "https://kolonie.ai/?asn-probe=$TS"
sleep 6
ssh <host> "grep -iaA 22 'asn-probe=$TS' /tmp/cap-$TS.txt \
  | grep -iaE 'GET /|cf-ip|cf-timezone|x-kolonie-asn|cf-connecting-ip|x-forwarded-for'; rm -f /tmp/cap-$TS.txt"
```

Keep the window short and delete the capture. It is our own origin and a few
seconds of it, but a packet capture of production traffic is not a thing to leave
lying in `/tmp`.

Observed 2026-08-02 with both changes applied — everything a proxied request now
carries at the origin. **Values that locate a person are masked here**; the header
names and the shape are the finding, and this file is public:

```
GET /?visitor-probe=… HTTP/1.1
Cf-Connecting-Ip: <caller>
Cf-Ipcountry:     DE
Cf-Ipcontinent:   EU
Cf-Ipcity:        <city>
Cf-Region:        <region>
Cf-Region-Code:   <code>
Cf-Postal-Code:   <postcode>
Cf-Iplatitude:    <lat>
Cf-Iplongitude:   <lon>
Cf-Timezone:      Europe/Berlin
Cf-Visitor:       {"scheme":"https"}
Cf-Ray:           …-TXL
X-Forwarded-For:  <caller>, <cloudflare-edge>
X-Kolonie-Asn:    3209
```

Three things this capture settles that the documentation would not have:

- **`cf-postal-code`, not `cf-ippostalcode`.** Cloudflare's own list gives the
  second name
- **No `cf-metro-code`.** It is a US metro/DMA code, sent for US visitors only
- **`x-kolonie-asn` is correct** — 3209 is the caller's ISP, and it is the field
  that distinguishes a home connection from a rented VPS, which is the whole reason
  for the rule

`X-Forwarded-For` carrying two entries is `#56`, not this change, and it is here
because the same capture shows it.

Note that a location this precise is now on every request. That is a fact for
whatever stores it (`kolonie-platform#191`) to decide about — lat/long and postal
code are not the same class of data as a country, and the Colony choosing to
receive them is not the same as choosing to keep them.
