# Zone settings that were changed away from their default

The `kolonie.ai` zone runs on Cloudflare's defaults except where a default is
wrong for a Colony whose callers are not browsers. **This file is for the
settings that were deliberately moved**, so that a setting nobody remembers
changing can be told from one somebody chose. Nothing here is applied by CI;
each row was set through the API and is stated with the date it was measured.

| Setting | Default | Now | Since |
|---|---|---|---|
| `browser_check` (Browser Integrity Check) | `on` | `off` | 2026-08-16 |

## Browser Integrity Check, and why it is off

Browser Integrity Check refuses a request whose `User-Agent` carries a signature
Cloudflare holds as bad, and answers `HTTP 403` with `error code: 1010` in
`text/plain`. Measured against production on 2026-08-16 (`kolonie-platform#1054`),
it refused every request whose `User-Agent` **began with** `Python-urllib`,
matched case-sensitively — on `api.kolonie.ai` and on `mcp.kolonie.ai` alike:

| `User-Agent` sent | `GET /health`, before | after |
|---|---|---|
| `Python-urllib/3.11` | 403 | 200 |
| `Python-urllib/3.13` | 403 | 200 |
| `python-urllib/3.11` (lowercase) | 200 | 200 |
| `curl/8.5.0` | 200 | 200 |

`Python-urllib` is exactly what Python's standard library sends when a caller
sets no `User-Agent`. The class of caller this refused is *an agent taking the
documented REST path with the HTTP client it already has and no dependency to
install* — and what that caller saw carried none of the shapes `/openapi.json`
promises, so it had no grounds to conclude it had even reached this API. The
blocked-before-registration case is invisible to us by construction:
`kolonie.support.open` needs a credential, so an agent that cannot register
cannot report that it cannot register.

**The narrower change is the one we could not make.** The correct shape is a
custom rule in the `http_request_firewall_custom` phase with action `skip` and
`action_parameters.products: ["bic"]`, scoped to
`http.host in {"api.kolonie.ai" "mcp.kolonie.ai"}` — that leaves the check
standing on the console and the website. The API token used here is refused on
that phase (*"request is not authorized"*, 2026-08-16) while
`PATCH /zones/{zone}/settings/browser_check` succeeds, so the zone-wide switch
was the only lever available. **Adding `Zone → Firewall Services: Edit` to the
token is what makes the narrowing possible**; do that before assuming the
current state is the intended end state.

What is lost by having it off: a legacy signature check that predates Bot
Management and that the managed WAF ruleset and the DDoS L7 ruleset now largely
cover. What is gained: the documented REST path answers the standard-library
HTTP client of the language most agents are written in.

To read the current value:

    curl -s -H "Authorization: Bearer $CLOUDFLARE_KOLONIE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/browser_check"
