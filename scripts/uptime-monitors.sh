#!/bin/bash
# Kolonie AI — the check that runs off this host, as configuration (#69)
#
# Every other monitor in this repository runs on the machine it watches, or in
# GitHub Actions. Both die with the thing they are watching: Docker's health
# checks are a container being asked about itself on a host that may not be
# running, and Actions disables a scheduled workflow after 60 days of repository
# inactivity. This one lives at UptimeRobot, outside both, and asks the five
# `/health` endpoints from the internet.
#
# The service is external and its state is not in Git — which is the failure this
# file exists against. `kolonie-infra#69`: *"An external dependency nobody can
# find the login for is worse than none, because it is believed in."* So the
# **desired** state is here, in DESIRED and the constants beside it, and this
# script is the only thing that writes it.
#
#   ./scripts/uptime-monitors.sh report   what the account currently holds
#   ./scripts/uptime-monitors.sh check    does it match DESIRED — writes nothing
#   ./scripts/uptime-monitors.sh apply    make it match DESIRED
#
# Needs UPTIMEROBOT_API_KEY in the environment. It is a repository secret in
# kolonie-infra and lives nowhere else; run this through
# `.github/workflows/uptime-monitors.yml` rather than pasting the key anywhere.
#
# ## Why the v3 API and not the documented v2 one
#
# Measured 2026-08-04, and it cost four runs to find, so it is written down here
# rather than left to be rediscovered: **this account's key reads over v2 and
# cannot write over it.** Every `newMonitor` call — with alert contacts, without
# them, with an interval, with nothing but a URL and a type — answers:
#
#     access_denied: You are not allowed to use some settings with your current plan.
#
# The obvious conclusion is wrong. The key is not read-only (a read-only key is
# prefixed `ur`; this one is not) and the plan is not the limit either: the same
# key creates the same monitor over the v3 API in one call. What v2 refuses is
# writing at all, and it refuses it with a message about settings.
#
# v3 is also the only one of the two that can say what this issue asks for.
# `sslExpirationReminder` and `keywordType` are v3 fields; the v2 monitor object
# carries no SSL key at all unless `ssl=1` is passed, and no way to set one.
#
# ## Nothing here ever deletes a monitor, and that is deliberate
#
# The account is the maintainer's own and holds unrelated monitors. A reconciler
# that removes what is not in its list would take those with it the first time it
# ran. The rule: a monitor whose URL is not in DESIRED is not this script's
# business, is never edited, is never deleted, and is reported only as a count.
#
# Exit status: 0 when the account matches DESIRED (or was made to), 1 when it
# does not and `check` was asked, 2 when the API could not be reached or refused.
# `apply` failing halfway is safe to re-run — every write is keyed on the URL, so
# a monitor that already exists is edited rather than duplicated.

set -uo pipefail

API="https://api.uptimerobot.com/v3"

# Five endpoints, each asked separately.
#
# **Not the apex, and not one of them standing for the others.** `kolonie.ai` is
# a static site served by nginx and will answer long after the API, the database
# or the runners have stopped — a check that watches only the front door reports
# green through the outage it exists to catch. These are the five services that
# answer `/health`, and one being down is a different fact from another being
# down.
#
# `name|url` — the URL is the identity. Renaming a monitor in the dashboard is
# harmless; changing its URL creates a new one and leaves the old, which is the
# behaviour wanted from a script that never deletes.
#
# **The sixth is not an endpoint and is the one that carries `#103`.** The first
# five ask *is this service answering*. `pressure.json` answers *is this host
# about to stop being able to serve any of them* — a disk over threshold, inodes
# exhausted, or a backup that has stopped happening. `#69` sent those to a GitHub
# issue and `#103` says that is the wrong side of the line it drew: they get
# worse on their own, and the issue announcing one sits in a list nobody is
# looking at on a Sunday.
#
# **It needs no new alerting service, which `#103` requires**, because the shape
# already fits: `kolonie-pressure.timer` on the host writes the keyword while the
# three conditions hold and writes something else when they do not, and
# `ALERT_NOT_EXISTS` turns *the disk is full* into *the keyword is gone*. A file
# that stops being written, or a host that stops serving it, alarms for the same
# reason and by the same route — which is the inversion `#103` asks for.
#
# `scripts/pressure-report.sh` holds what it does and does not publish.
read -r -d '' DESIRED <<'EOF'
kolonie api /health|https://api.kolonie.ai/health
kolonie academy /health|https://academy.kolonie.ai/health
kolonie mcp /health|https://mcp.kolonie.ai/health
kolonie challenge /health|https://challenge.kolonie.ai/health
kolonie console /health|https://console.kolonie.ai/health
kolonie host pressure|https://kolonie.ai/status/pressure.json
EOF

# A keyword monitor, because all five answer `{"status":"ok"}` and a plain HTTP
# monitor would call a 200 saying `"degraded"` a pass. `ALERT_NOT_EXISTS` alerts
# when the string is *absent*; `ALERT_EXISTS` is the opposite and is the easy
# mistake here, since it would page only while everything was fine.
MONITOR_TYPE="KEYWORD"
KEYWORD_TYPE="ALERT_NOT_EXISTS"
KEYWORD_VALUE='"status":"ok"'
KEYWORD_CASE="CaseSensitive"

# Five minutes, the free tier's floor. Better Stack's 30 seconds was the argument
# for the other provider and lost to the account already existing (#69,
# 2026-08-03); five minutes to notice a dead host is well inside the time it
# takes anyone to act on it.
INTERVAL="${UPTIME_INTERVAL:-300}"

# Thirty seconds, against a `/health` that answers in tens of milliseconds. Long
# enough that a slow moment is not an outage, short enough that a hung endpoint
# is reported within the interval rather than the one after it.
TIMEOUT=30

# **The certificate, and the two halves of it that are not the same question.**
#
# `checkSSLErrors` makes an expired or otherwise invalid certificate a *down*, so
# the alert arrives when it breaks. `sslExpirationReminder` is the warning some
# days *before* — and this account cannot have it: `PATCH` with that one field
# and nothing else answers `403 009-005 You are not allowed to use some settings
# with your current plan`, measured 2026-08-04 by changing one setting at a time.
# Every other field in this file was accepted in the same run, which is how it is
# known to be that one and not the shape of the request.
#
# So what is covered is *the certificate has failed*, within five minutes, on all
# five endpoints. What is not is *it will fail on Friday*. Traefik renews from
# Let's Encrypt automatically at 30 days remaining, so the gap is the case where
# renewal itself is broken — which this catches, late, as an outage rather than
# as a warning. Upgrading the plan is the only way to close it, and it is not
# worth an upgrade; the line to change is one boolean below if that ever changes.
#
# Domain expiry is deliberately left alone: the registration is renewed by
# nothing in this repository, and five identical reminders for one domain is
# noise.
CHECK_SSL_ERRORS=true
SSL_EXPIRATION_REMINDER=false

die() {
    echo "ERROR: $*" >&2
    exit 2
}

command -v jq >/dev/null || die "jq is not installed"
[ -n "${UPTIMEROBOT_API_KEY:-}" ] || die "UPTIMEROBOT_API_KEY is not set"

# Every call carries the key as a bearer token and answers JSON. The body is
# printed on failure but the request never is — the key is in the header, and a
# workflow log is not a private place.
api() {
    local method="$1" path="$2" body="${3:-}"
    local -a args=(--silent --show-error --max-time 30
        -w '\n%{http_code}'
        -X "$method"
        -H "Authorization: Bearer ${UPTIMEROBOT_API_KEY}"
        -H "Content-Type: application/json")
    [ -n "$body" ] && args+=(-d "$body")

    local out code
    out=$(curl "${args[@]}" "${API}${path}") || die "${method} ${path}: curl failed"
    code=$(printf '%s' "$out" | tail -n1)
    out=$(printf '%s' "$out" | sed '$d')

    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        printf '%s\n' "$out" | head -c 500 >&2
        echo >&2
        die "${method} ${path}: HTTP ${code}"
    fi
    printf '%s' "$out"
}

# Every monitor on the account. `limit` is 50 against an account holding 15 on
# 2026-08-04 — sized to be unreachable rather than sized to the account, for the
# reason `kolonie-docs/AGENTS.md` §6 gives about `--limit`: a page boundary below
# the real count does not fail, it answers a shorter and plausible lie. The
# response carries `nextLink` when there is more, and this asserts there is not
# rather than paginating a list that should never need it.
all_monitors() {
    local out
    out=$(api GET "/monitors?limit=50") || return 2
    if [ "$(printf '%s' "$out" | jq -r '.nextLink // "" | length')" != "0" ]; then
        die "the account holds more than 50 monitors — this script would only see the first page"
    fi
    printf '%s' "$out"
}

# Which alert contacts a monitor should carry: every *active* one on the account,
# at threshold 0 and recurrence 0, which is "tell me once, immediately".
#
# Read from the account rather than written down here. The account is the
# maintainer's, its contacts are where the maintainer reads, and a contact id
# pinned in this file would be a number that goes stale silently — the alert
# would go on being configured and stop arriving.
want_contacts_json() {
    api GET "/alert-contacts" |
        jq -c '[.data[] | select(.status == "Active")
               | {alertContactId: .id, threshold: 0, recurrence: 0}]'
}

# The body of a create or an edit. Identical for both, which is the point: there
# is one description of a correct monitor and both paths write it.
desired_body() {
    local name="$1" url="$2" contacts="$3"
    jq -n -c \
        --arg name "$name" --arg url "$url" --arg type "$MONITOR_TYPE" \
        --arg ktype "$KEYWORD_TYPE" --arg kvalue "$KEYWORD_VALUE" --arg kcase "$KEYWORD_CASE" \
        --argjson interval "$INTERVAL" --argjson timeout "$TIMEOUT" \
        --argjson ssl_errors "$CHECK_SSL_ERRORS" --argjson ssl_reminder "$SSL_EXPIRATION_REMINDER" \
        --argjson contacts "$contacts" \
        '{friendlyName: $name, url: $url, type: $type,
          keywordType: $ktype, keywordValue: $kvalue, keywordCaseType: $kcase,
          interval: $interval, timeout: $timeout,
          checkSSLErrors: $ssl_errors, sslExpirationReminder: $ssl_reminder,
          assignedAlertContacts: $contacts}'
}

# What is wrong with the monitor as it stands, field by field rather than as a
# digest, so the report can name what drifted instead of only that something did.
drift_reasons() {
    local monitor="$1" contacts="$2"
    printf '%s' "$monitor" | jq -r \
        --arg type "$MONITOR_TYPE" --arg ktype "$KEYWORD_TYPE" --arg kvalue "$KEYWORD_VALUE" \
        --argjson interval "$INTERVAL" --argjson timeout "$TIMEOUT" \
        --argjson ssl_errors "$CHECK_SSL_ERRORS" --argjson ssl_reminder "$SSL_EXPIRATION_REMINDER" \
        --argjson contacts "$contacts" '
        [ if .type != $type then "type \(.type)≠\($type)" else empty end,
          if .keywordType != $ktype then "keywordType \(.keywordType // "none")≠\($ktype)" else empty end,
          if .keywordValue != $kvalue then "keyword \(.keywordValue // "none")≠\($kvalue)" else empty end,
          if .interval != $interval then "interval \(.interval)s≠\($interval)s" else empty end,
          if .timeout != $timeout then "timeout \(.timeout)s≠\($timeout)s" else empty end,
          if .checkSSLErrors != $ssl_errors then "checkSSLErrors \(.checkSSLErrors)≠\($ssl_errors)" else empty end,
          if .sslExpirationReminder != $ssl_reminder then "sslExpirationReminder \(.sslExpirationReminder)≠\($ssl_reminder)" else empty end,
          # A monitor somebody paused is drift too, and the worst kind: the
          # dashboard shows it, nothing else does, and a paused check reports
          # green for ever.
          if .status == "PAUSED" then "paused" else empty end,
          ( ([.assignedAlertContacts[]?.alertContactId] | sort) as $have
          | ([$contacts[].alertContactId] | sort) as $want
          | if $have != $want then "alert contacts \($have)≠\($want)" else empty end )
        ] | join(", ")'
}

cmd_report() {
    local monitors total ours
    monitors=$(all_monitors) || return 2
    total=$(printf '%s' "$monitors" | jq -r '.data | length')

    echo "== the five endpoints =="
    while IFS='|' read -r name url; do
        [ -n "$url" ] || continue
        # `[…][0]`, not a bare `.data[] | select(…)`. An empty jq stream produces
        # no output at all, so a missing monitor printed a blank line — the report
        # said least exactly when it had most to say. Indexing yields null, and
        # null is a value the `if` can see.
        printf '%s' "$monitors" | jq -r --arg url "$url" --arg name "$name" '
            ([.data[] | select(.url == $url)][0]) as $m
            | if $m == null then "\($name)\n  MISSING"
              else "\($name)\n  id \($m.id)  \($m.type)  \($m.status)  every \($m.interval)s" +
                   "  keyword \($m.keywordValue // "none") (\($m.keywordType // "-"))" +
                   "  contacts \([$m.assignedAlertContacts[]?.alertContactId] | join(","))" +
                   "\n  TLS: errors alert \($m.checkSSLErrors)  expiry reminder \($m.sslExpirationReminder)" +
                   "  certificate expires \($m.sslExpiryDateTime // "unknown") (\($m.sslBrand // "?"))"
              end'
    done <<<"$DESIRED"

    ours=$(printf '%s' "$monitors" | jq -r '[.data[] | select(.url | test("^https://[a-z]+\\.kolonie\\.ai/health$"))] | length')
    echo
    echo "== the rest of the account =="
    # The names and URLs of monitors that are not ours are the maintainer's
    # private business, and this runs in public CI. The count is the whole
    # report: it exists to say "this account is shared, do not reconcile by
    # deletion", which is a number and not a list.
    echo "$((total - ours)) monitor(s) on this account are not the Colony's — never touched by this script"

    echo
    echo "== where an alert goes =="
    # The address is masked. Which contact, and that it is active, is the fact
    # worth reporting; the address itself is the maintainer's.
    api GET "/alert-contacts" | jq -r '
        .data[] | "\(.id)  \(.type)  \(.status)  \(.value // "" | if length > 4 then .[0:2] + "…" + .[-2:] else "…" end)"'
}

cmd_apply() {
    local write="$1" # "apply" or "check"
    local contacts rc=0
    contacts=$(want_contacts_json) || return 2
    [ "$(printf '%s' "$contacts" | jq -r 'length')" != "0" ] ||
        die "the account has no active alert contact — an alert nobody receives is not a check"

    local monitors
    monitors=$(all_monitors) || return 2

    local name url monitor id reasons
    while IFS='|' read -r name url; do
        [ -n "$url" ] || continue
        monitor=$(printf '%s' "$monitors" | jq -c --arg url "$url" '[.data[] | select(.url == $url)][0]')

        if [ "$monitor" = "null" ]; then
            if [ "$write" = "check" ]; then
                echo "MISSING  $name"
                rc=1
                continue
            fi
            id=$(api POST "/monitors" "$(desired_body "$name" "$url" "$contacts")" | jq -r '.id') || return 2
            echo "created  $name  (id $id)"
            continue
        fi

        reasons=$(drift_reasons "$monitor" "$contacts")
        if [ -z "$reasons" ]; then
            echo "ok       $name"
            continue
        fi

        if [ "$write" = "check" ]; then
            echo "DRIFTED  $name  ($reasons)"
            rc=1
            continue
        fi

        id=$(printf '%s' "$monitor" | jq -r '.id')

        # **The one case where this script deletes, and the fence around it.**
        #
        # `PATCH` answers `009-015 Monitor type cannot be changed after creation`,
        # so a monitor of the wrong type cannot be fixed in place — it has to go
        # and come back. That is a delete, which everything else here refuses to
        # do, and the fence is that the URL is one of DESIRED's five: this
        # script only ever deletes something it would create in the next line.
        # A monitor it did not put there is still never touched.
        #
        # What is lost is that monitor's uptime history. That is the real cost
        # and it is accepted: a monitor of the wrong type is measuring the wrong
        # thing, so its history is a record of the wrong question.
        if [[ "$reasons" == *"type "* ]]; then
            api DELETE "/monitors/${id}" >/dev/null || return 2
            id=$(api POST "/monitors" "$(desired_body "$name" "$url" "$contacts")" | jq -r '.id') || return 2
            echo "recreated $name  (id $id — $reasons; the type cannot be changed in place)"
            continue
        fi

        api PATCH "/monitors/${id}" "$(desired_body "$name" "$url" "$contacts")" >/dev/null || return 2
        echo "fixed    $name  ($reasons)"
    done <<<"$DESIRED"

    return $rc
}

# Break one monitor on purpose, watch it go down, and put it back.
#
# `#69`'s definition of done is *"a deliberate failure produced a real alert"* —
# and that is not a one-off. An alert path is exactly the kind of thing that
# stops working silently: a contact deactivated, an address that started
# bouncing, a plan change. This is the drill, re-runnable, so the answer can be
# taken again rather than remembered from the day it was built.
#
# **It breaks the keyword, not the service and not the URL.** The endpoint keeps
# answering `{"status":"ok"}` to everybody else; this monitor is simply told to
# look for a string that is not there, so it fails its check and opens a real
# incident down the real alert path. Nothing in production is touched, and the
# blast radius if this script dies mid-drill is one monitor watching for the
# wrong word — which the weekly `check` reports as drift and `apply` repairs.
cmd_drill() {
    local url="https://console.kolonie.ai/health"
    local name="kolonie console /health"
    local contacts monitor id
    contacts=$(want_contacts_json) || return 2
    monitor=$(all_monitors | jq -c --arg url "$url" '[.data[] | select(.url == $url)][0]')
    [ "$monitor" != "null" ] || die "no monitor for ${url} — run apply first"
    id=$(printf '%s' "$monitor" | jq -r '.id')

    # Read back through the list rather than a per-monitor GET: the list is the
    # one read this script already knows answers, and one endpoint fewer to be
    # wrong about.
    monitor_status() {
        all_monitors | jq -r --arg id "$id" '[.data[] | select((.id|tostring) == $id)][0].status // "?"'
    }

    echo "drill: monitor $id ($name) is being told to look for a keyword that is not there"
    api PATCH "/monitors/${id}" '{"keywordValue":"\"status\":\"this-is-a-drill\""}' >/dev/null || return 2

    # Up to twelve minutes: the check interval is five, UptimeRobot confirms a
    # failure with a second attempt before opening an incident, and the poll
    # below is the only thing here that can be slow.
    local waited=0 status=""
    while [ "$waited" -lt 720 ]; do
        sleep 30
        waited=$((waited + 30))
        status=$(monitor_status)
        echo "  ${waited}s: $status"
        [ "$status" = "DOWN" ] && break
    done

    echo "incident:"
    all_monitors | jq -c --arg id "$id" '[.data[] | select((.id|tostring) == $id)][0] | {status, lastIncident, lastIncidentId}'

    echo "restoring"
    api PATCH "/monitors/${id}" "$(desired_body "$name" "$url" "$contacts")" >/dev/null || return 2
    waited=0
    while [ "$waited" -lt 720 ]; do
        sleep 30
        waited=$((waited + 30))
        status=$(monitor_status)
        echo "  ${waited}s: $status"
        [ "$status" = "UP" ] && break
    done

    [ "$status" = "UP" ] || die "the drill monitor did not come back up — fix it before trusting the check"
    echo "drill complete, $name is UP again"
}

case "${1:-report}" in
report) cmd_report ;;
check) cmd_apply check ;;
apply) cmd_apply apply ;;
drill) cmd_drill ;;
*)
    echo "usage: $0 [report|check|apply]" >&2
    exit 2
    ;;
esac
