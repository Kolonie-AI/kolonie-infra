#!/bin/bash
# What the apex host's routers promise each other (#150).
#
# Usage: ./scripts/check-routes.sh
#
# ## Why this exists when the routers are four lines each
#
# `kolonie.ai` is split between two services. `website` serves the static Astro
# site and answers `Host(`kolonie.ai`)` with nothing else, so it is the
# **catch-all**; `atlas`, `profile` and `playbooks` take a path prefix each and
# hand it to the API. That arrangement is correct only while the prefixed routers outrank the
# catch-all, and Traefik defaults a router's priority to **the length of its
# rule**.
#
# The Atlas router's own comment names the cost of leaving that inherited:
#
#     an accident of spelling, and rewording the website rule below would
#     silently take the Atlas down and serve the static 404 instead
#
# Both prefixed routers carry an explicit `priority:` for that reason. What was
# missing is anything that *checks* it — the comment is an argument and the next
# person to add a router on this host will not have read it. A rule that loses
# its precedence fails in production, on live traffic, and looks like a 404
# rather than like a configuration error.
#
# ## What it asserts, and what it deliberately does not
#
# **The precedence and the shape of the rules, not Traefik's behaviour.** This
# cannot run Traefik, and proving that a higher `priority` wins would be testing
# Traefik. What it can do is refuse a configuration in which the question arises:
# every router splitting the apex host states a priority, and every one of them
# is above the catch-all's.
#
# **`@` is checked as a matcher question rather than a live request**, for the
# same reason. Traefik matches on the decoded path, so `/%40handle` and
# `/@handle` reach the same rule — what this asserts is that the rule is written
# so that they can, which is the part a diff can be wrong about.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROUTES="$ROOT/traefik/dynamic/routes.yml"

FAILURES=0

check() {
    local name=$1 ok=$2 detail=${3:-}
    if [ "$ok" = yes ]; then
        printf '  ok   %s\n' "$name"
    else
        printf '  FAIL %s\n' "$name"
        [ -n "$detail" ] && printf '%s\n' "$detail" | sed 's/^/         /'
        FAILURES=$((FAILURES + 1))
    fi
}

[ -f "$ROUTES" ] || { echo "no $ROUTES"; exit 2; }

# The rule text of one router, read from the block that follows its name. Comment
# lines are dropped first: every one of these routers documents the rule it is
# about, quoting it, and a check that matched its own explanation would be paid
# for by deleting the explanation.
rule_of() {
    grep -vE '^[[:space:]]*#' "$ROUTES" |
        awk -v want="$1" '
            $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { inside = 1; next }
            inside && /^[[:space:]]*rule:/ { sub(/^[[:space:]]*rule:[[:space:]]*/, ""); print; exit }
            inside && /^[[:space:]]*[a-z-]+:[[:space:]]*$/ { inside = 0 }
        '
}

priority_of() {
    grep -vE '^[[:space:]]*#' "$ROUTES" |
        awk -v want="$1" '
            $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { inside = 1; next }
            inside && /^[[:space:]]*priority:/ { print $2; exit }
            inside && /^[[:space:]]*rule:/ { next }
            inside && /^[[:space:]]*[a-z-]+:[[:space:]]*$/ { inside = 0 }
        '
}

echo
echo "the apex host is split, and every splitter outranks the catch-all"

website_rule=$(rule_of website)
check "the catch-all is still \`website\`, matching the host and nothing else" \
    "$([ "$website_rule" = '"Host(`kolonie.ai`)"' ] && echo yes || echo no)" \
    "read: $website_rule
if this grew a path matcher, the reasoning below no longer describes this file"

# Every router that names the apex host *and* a path. These are the ones whose
# correctness depends on beating the catch-all.
splitters=$(grep -vE '^[[:space:]]*#' "$ROUTES" |
    awk '/^[[:space:]]*[a-z][a-z0-9-]*:[[:space:]]*$/ { name = $1; sub(/:$/, "", name) }
         /^[[:space:]]*rule:.*kolonie\.ai.*PathPrefix/ { print name }')

check "at least one router splits the apex host" \
    "$([ -n "$splitters" ] && echo yes || echo no)" \
    "if these were renamed, this check is asserting nothing"

for router in $splitters; do
    priority=$(priority_of "$router")
    if [ -z "$priority" ]; then
        check "$router states a priority" no \
            "Traefik would default it to the rule's length, so this router's
precedence over \`website\` becomes an accident of how either rule is spelled"
        continue
    fi
    check "$router states a priority ($priority)" yes

    # The catch-all inherits `len("Host(\`kolonie.ai\`)")`. Comparing against the
    # literal length rather than a magic number, so this stays true if the rule
    # is reworded — which is the exact change the Atlas comment warns about.
    inherited=${#website_rule}
    if [ "$priority" -gt "$inherited" ]; then
        check "$router outranks the catch-all's inherited $inherited" yes
    else
        check "$router outranks the catch-all's inherited $inherited" no \
            "priority $priority does not beat $inherited — this router would serve
the static site's 404 instead of the API"
    fi
done

echo
echo "a citizen's page is reachable by both spellings of its prefix"

profile_rule=$(rule_of profile)
check "the profile router exists" \
    "$([ -n "$profile_rule" ] && echo yes || echo no)" \
    "kolonie-platform#819 renders a page nothing routes to"

# **Traefik matches `PathPrefix` against the escaped path**, so `/@` and `/%40`
# are two different prefixes and both have to be named. This check asserted the
# opposite until 2026-08-14 — it *refused* the encoded matcher, on the reading
# that Go hands the decoded path to the router — and it was wrong: Traefik v3
# uses `EscapedPath()`. Measured against the live host minutes after the rule
# went out:
#
#     /@Fermata      200  <title>Fermata — Kolonie
#     /%40Fermata    404  <title>Not found | Kolonie AI
#
# **A check that enforces the bug is worse than no check**, which is what this
# was: it would have refused the fix. So the assertion below is written from
# that measurement and not from how the matcher ought to behave, and the two
# lines are here so the next person can re-measure rather than re-reason.
check "the canonical prefix is matched" \
    "$(printf '%s' "$profile_rule" | grep -qF 'PathPrefix(`/@`)' && echo yes || echo no)" \
    "read: $profile_rule"

check "and the percent-encoded prefix is matched too" \
    "$(printf '%s' "$profile_rule" | grep -qF 'PathPrefix(`/%40`)' && echo yes || echo no)" \
    "read: $profile_rule
without it, a client that percent-encodes gets the static site's 404 while a
browser gets the page — which reads as a broken client rather than a broken rule"

check "the permanent-redirect prefix reaches the API too" \
    "$(printf '%s' "$profile_rule" | grep -qF 'PathPrefix(`/citizens`)' && echo yes || echo no)" \
    "kolonie-docs#319 made /citizens/{handle} a 301 to /@{handle}, and the API owns
that redirect — so this proxy has to hand it the request rather than answer it"

echo
echo "the API answers for its own paths, including when the answer is 404"

# An `errors` middleware on these routers would replace *no citizen by that name*
# with a proxy error page, which is a different claim: the first says the handle
# is free, the second says the site is broken.
for router in atlas profile playbooks; do
    block=$(grep -vE '^[[:space:]]*#' "$ROUTES" |
        awk -v want="$router" '
            $0 ~ "^[[:space:]]*" want ":[[:space:]]*$" { inside = 1; next }
            inside && /^[[:space:]]*[a-z][a-z0-9-]*:[[:space:]]*$/ && !/middlewares|tls/ { exit }
            inside { print }
        ')
    check "$router does not intercept its own 404" \
        "$(printf '%s' "$block" | grep -qE '^\s+- errors' && echo no || echo yes)" \
        "an errors middleware here turns an unknown handle into a broken site"
done

echo
echo "each host-only router answers for its own host and nothing else"

# #241 required \"a request without Host: workplace.kolonie.ai does not reach
# this router — verified, not assumed\". This cannot run Traefik, so it asserts
# the property that makes the claim true: the rule is a bare `Host(...)` on one
# name, with no path matcher and no second hostname ORed in. A rule shaped that
# way cannot match another host, and that is the part a diff can get wrong.
#
# The measurement that motivated this is on the live host, recorded on the
# issue: before the router existed the name answered 525, and afterwards a
# request to a *different* host was still served by that host's own router.
for router in console workplace; do
    r=$(rule_of "$router")
    host="${router}.kolonie.ai"
    [ "$router" = console ] && host="console.kolonie.ai"

    check "$router matches exactly one host and no path" \
        "$([ "$r" = "\"Host(\`$host\`)\"" ] && echo yes || echo no)" \
        "read: $r
a path matcher or a second host here means this router can answer for a name
its comment does not describe"
done

# The workplace is the one router in this file that must not be pointed at the
# api service. Routing it there would collapse the console and the workplace
# into one product, which is the thing #241 exists to prevent, and it would do
# so silently — the host would answer 200 and serve the wrong application.
workplace_service=$(grep -vE '^[[:space:]]*#' "$ROUTES" |
    awk '
        /^[[:space:]]*workplace:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]*service:/ { print $2; exit }
        inside && /^[[:space:]]*[a-z][a-z0-9-]*:[[:space:]]*$/ && !/middlewares|tls/ { inside = 0 }
    ')
check "the workplace router does not answer from the api service" \
    "$([ "$workplace_service" = workplace ] && echo yes || echo no)" \
    "read service: ${workplace_service:-<none>}
#241: this host is a separate Vue application, not a surface of apps/api"

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failed"
    exit 1
fi
echo "all good"
