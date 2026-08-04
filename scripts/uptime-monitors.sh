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
# **desired** state is here, in DESIRED below, and the script is the only thing
# that writes it.
#
#   ./scripts/uptime-monitors.sh report   what the account currently holds
#   ./scripts/uptime-monitors.sh check    does it match DESIRED — writes nothing
#   ./scripts/uptime-monitors.sh apply    make it match DESIRED
#
# Needs UPTIMEROBOT_API_KEY in the environment. It is a repository secret in
# kolonie-infra and lives nowhere else; run this through
# `.github/workflows/uptime-monitors.yml` rather than pasting the key anywhere.
#
# **Nothing here ever deletes a monitor, and that is deliberate.** The account is
# the maintainer's own and holds unrelated monitors. A reconciler that removes
# what is not in its list would take those with it the first time it ran. So the
# rule is: a monitor whose URL is not in DESIRED is not this script's business,
# is never edited, is never deleted, and is reported only as a count.
#
# Exit status: 0 when the account matches DESIRED (or was made to), 1 when it
# does not and `check` was asked, 2 when the API could not be reached or refused.
# `apply` failing halfway is safe to re-run — every write is keyed on the URL, so
# a monitor that already exists is edited rather than duplicated.

set -uo pipefail

API="https://api.uptimerobot.com/v2"

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
read -r -d '' DESIRED <<'EOF'
kolonie api /health|https://api.kolonie.ai/health
kolonie academy /health|https://academy.kolonie.ai/health
kolonie mcp /health|https://mcp.kolonie.ai/health
kolonie challenge /health|https://challenge.kolonie.ai/health
kolonie console /health|https://console.kolonie.ai/health
EOF

# Type 2 is a keyword monitor, and the extra field is worth the trouble.
#
# All five endpoints answer `{"status":"ok"}`. A plain HTTP monitor (type 1)
# alerts on a non-2xx or a timeout and would call a 200 saying `"degraded"` a
# pass. Asking for the string means the check fails on the answer as well as on
# the connection, for no extra cost and no extra request.
MONITOR_TYPE=2
KEYWORD_VALUE='"status":"ok"'
# 2 = alert when the keyword is *absent*. 1 is the opposite and is the easy
# mistake here: it would page only while everything was fine.
KEYWORD_TYPE=2

# Five minutes, because that is the free tier's floor and this account is on it.
# Better Stack's 30 seconds was the argument for the other provider and lost to
# the account already existing (#69, 2026-08-03). Five minutes to notice a dead
# host is far inside the time it takes anyone to do anything about it.
INTERVAL="${UPTIME_INTERVAL:-300}"

die() {
    echo "ERROR: $*" >&2
    exit 2
}

command -v jq >/dev/null || die "jq is not installed"
[ -n "${UPTIMEROBOT_API_KEY:-}" ] || die "UPTIMEROBOT_API_KEY is not set"

# Every call is a POST with the key in the body — UptimeRobot's v2 API has no
# other shape. `--data-urlencode` rather than `-d` because the keyword carries
# quotes and a colon.
call() {
    local endpoint="$1"
    shift
    local args=(--silent --show-error --max-time 30
        --data-urlencode "api_key=${UPTIMEROBOT_API_KEY}"
        --data-urlencode "format=json")
    local a
    for a in "$@"; do args+=(--data-urlencode "$a"); done

    local out
    out=$(curl "${args[@]}" "${API}/${endpoint}") || die "${endpoint}: curl failed"

    # A refused key answers 200 with stat=fail, so the HTTP status proves
    # nothing. Check what it said.
    local stat
    stat=$(printf '%s' "$out" | jq -r '.stat // "unparseable"')
    if [ "$stat" != "ok" ]; then
        # The error message can quote the request back, so print only the
        # structured error and never the raw body — the key was in the request.
        printf '%s' "$out" | jq -r '.error | "\(.type // "?"): \(.message // "?")"' >&2
        die "${endpoint}: the API refused the call"
    fi
    printf '%s' "$out"
}

# Alert contacts, as UptimeRobot wants them on a monitor: id_threshold_recurrence
# joined by dashes. Threshold 0 and recurrence 0 mean "tell me once, immediately".
#
# Every *active* contact on the account is attached rather than a hard-coded id.
# The account is the maintainer's, its contacts are where the maintainer reads,
# and an id written down here would be a number that goes stale silently — the
# alert would keep being configured and stop arriving.
alert_contact_args() {
    local contacts
    contacts=$(call getAlertContacts) || return 1
    printf '%s' "$contacts" |
        jq -r '[.alert_contacts[] | select(.status == 2) | "\(.id)_0_0"] | join("-")'
}

# What the account holds for our five URLs, one TSV row each:
#   url  id  friendly_name  type  keyword_type  keyword_value  interval  status
current_monitors() {
    call getMonitors "logs=0" "alert_contacts=1" |
        jq -r '.monitors[] | [.url, (.id|tostring), .friendly_name, (.type|tostring),
                              ((.keyword_type // 0)|tostring), (.keyword_value // ""),
                              (.interval|tostring), (.status|tostring),
                              ([.alert_contacts[]?.id] | sort | join(","))]
                             | @tsv'
}

# Does this monitor already say what DESIRED says. Compared field by field rather
# than by a digest so the report can name which one drifted.
drift_reasons() {
    local type="$1" ktype="$2" kvalue="$3" interval="$4" contacts="$5" want_contacts="$6"
    local reasons=""
    add() { reasons="${reasons:+$reasons, }$1"; }
    [ "$type" = "$MONITOR_TYPE" ] || add "type $type≠$MONITOR_TYPE"
    [ "$ktype" = "$KEYWORD_TYPE" ] || add "keyword_type $ktype≠$KEYWORD_TYPE"
    [ "$kvalue" = "$KEYWORD_VALUE" ] || add "keyword ${kvalue:-none}≠${KEYWORD_VALUE}"
    [ "$interval" = "$INTERVAL" ] || add "interval ${interval}s≠${INTERVAL}s"
    [ "$contacts" = "$want_contacts" ] || add "alert contacts ${contacts:-none}≠${want_contacts:-none}"
    printf '%s' "$reasons"
}

cmd_report() {
    local monitors total ours
    monitors=$(call getMonitors "logs=0" "alert_contacts=1") || return 2
    total=$(printf '%s' "$monitors" | jq -r '.monitors | length')

    echo "== the five endpoints =="
    printf '%s\n' "$DESIRED" | while IFS='|' read -r name url; do
        [ -n "$url" ] || continue
        printf '%s' "$monitors" | jq -r --arg url "$url" --arg name "$name" '
            (.monitors[] | select(.url == $url)) as $m
            | if $m then
                "\($name)\n  id \($m.id)  type \($m.type)  keyword \($m.keyword_value // "none")" +
                "  every \($m.interval)s  status \($m.status)  contacts \([$m.alert_contacts[]?.id] | length)"
              else "\($name)\n  MISSING" end' 2>/dev/null ||
            echo "$name"$'\n'"  MISSING"
    done

    ours=$(printf '%s' "$monitors" | jq -r '[.monitors[] | select(.url | test("^https://[a-z]+\\.kolonie\\.ai/health$"))] | length')
    echo
    echo "== the rest of the account =="
    # Names and URLs of monitors that are not ours are the maintainer's private
    # business and a workflow log is not a private place. The count is the whole
    # report: it exists to say "this account is shared, do not reconcile by
    # deletion", which is a number and not a list.
    echo "$((total - ours)) monitor(s) on this account are not the Colony's — never touched by this script"

    echo
    echo "== where an alert goes =="
    # Type 2 is e-mail, 11 is a webhook, and the rest are chat integrations. The
    # *value* is an address; it is masked because this runs in public CI.
    call getAlertContacts | jq -r '
        .alert_contacts[]
        | "\(.id)  type \(.type)  status \(.status)  \(.value | if length > 4 then .[0:2] + "…" + .[-2:] else "…" end)"'

    echo
    echo "== fields the account's API returns on a monitor (names only) =="
    # Names, never values — a foreign monitor's URL is not ours to print. It is
    # here because UptimeRobot's v2 documentation and its answers do not entirely
    # agree about which SSL fields exist, and a list read off the live account
    # settles that in one line instead of by argument.
    printf '%s' "$monitors" | jq -r '[.monitors[] | keys] | add | unique | join(" ")'
}

cmd_apply() {
    local write="$1" # "apply" or "check"
    local want_contacts rc=0
    want_contacts=$(alert_contact_args) || return 2
    [ -n "$want_contacts" ] || die "the account has no active alert contact — an alert nobody receives is not a check"

    local current
    current=$(current_monitors) || return 2

    local name url row id type ktype kvalue interval status contacts reasons
    while IFS='|' read -r name url; do
        [ -n "$url" ] || continue
        row=$(printf '%s\n' "$current" | awk -F'\t' -v u="$url" '$1 == u {print; exit}')

        if [ -z "$row" ]; then
            if [ "$write" = "check" ]; then
                echo "MISSING  $name"
                rc=1
                continue
            fi
            id=$(call newMonitor \
                "friendly_name=${name}" \
                "url=${url}" \
                "type=${MONITOR_TYPE}" \
                "keyword_type=${KEYWORD_TYPE}" \
                "keyword_value=${KEYWORD_VALUE}" \
                "interval=${INTERVAL}" \
                "alert_contacts=${want_contacts}" | jq -r '.monitor.id') || return 2
            echo "created  $name  (id $id)"
            continue
        fi

        IFS=$'\t' read -r _ id _ type ktype kvalue interval status contacts <<<"$row"
        reasons=$(drift_reasons "$type" "$ktype" "$kvalue" "$interval" \
            "$(printf '%s' "$contacts" | tr ',' '\n' | sort | paste -sd, -)" \
            "$(printf '%s' "$want_contacts" | tr '-' '\n' | cut -d_ -f1 | sort | paste -sd, -)")

        # status 0 is a monitor somebody paused. That is drift too, and the worst
        # kind: the dashboard shows it, nothing else does, and a paused check
        # reports green forever.
        if [ "$status" = "0" ]; then
            reasons="paused${reasons:+, $reasons}"
        fi

        if [ -z "$reasons" ]; then
            echo "ok       $name"
            continue
        fi

        if [ "$write" = "check" ]; then
            echo "DRIFTED  $name  ($reasons)"
            rc=1
            continue
        fi

        call editMonitor \
            "id=${id}" \
            "friendly_name=${name}" \
            "type=${MONITOR_TYPE}" \
            "keyword_type=${KEYWORD_TYPE}" \
            "keyword_value=${KEYWORD_VALUE}" \
            "interval=${INTERVAL}" \
            "status=1" \
            "alert_contacts=${want_contacts}" >/dev/null || return 2
        echo "fixed    $name  ($reasons)"
    done <<<"$DESIRED"

    return $rc
}

case "${1:-report}" in
report) cmd_report ;;
check) cmd_apply check ;;
apply) cmd_apply apply ;;
*)
    echo "usage: $0 [report|check|apply]" >&2
    exit 2
    ;;
esac
