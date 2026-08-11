#!/bin/bash
# Has the deploy pipeline stopped working? `kolonie-infra#124`.
#
# Usage:
#   deploy-alarm.sh check <report-file>   # ask; exit 1 if the alarm should stand
#
# ## The failure this exists to end
#
# Production ran a twenty-hour-old build for twenty hours and nothing said so.
# **Twenty consecutive deploy runs failed** between 2026-08-10 06:00 UTC and
# 2026-08-11 02:02 UTC, every one at the same line and every one before
# `deploy.sh` was reached, so not a single service was touched. The whole of the
# failure signalling was one line in `deploy.yml`:
#
#     - name: Notify on failure
#       if: failure()
#       run: echo "::error::Deployment failed! Check VPS logs."
#
# **A red run is not an alarm.** It is a mark on a page somebody has to open, and
# *nobody opening it* is the failure mode. Every other class of breakage here has
# a channel that comes to the reader — `red-on-main.yml`, the Health Watcher,
# `board-self-check.yml` all file issues. A failed deploy had nothing, which made
# it the one silent failure in a system that is noisy about far less.
#
# What eventually arrived was `#123`, filed by the Health Watcher, reporting that
# the deployed revision was *"behind by 28"*. That is the symptom. A watcher
# comparing revisions is the last line of defence: it can only fire once the
# drift is large enough to look wrong, and it cannot say why.
#
# ## Two repositories, and a watcher seeing one would have found six of nineteen
#
# `deploy.yml` runs here on pushes to `kolonie-infra`. It is **also**
# `workflow_call`-ed by `build-and-deploy.yml` in `kolonie-platform`, and a
# called workflow's run belongs to the *caller* — so those runs never appear in
# this repository at all.
#
# Measured over the outage: thirteen consecutive failures in `kolonie-platform`,
# six here. Either alone reads as a smaller, more forgivable problem than the
# nineteen that were actually happening.
#
# `workflow_run` cannot fire across repositories, so this is asked on a schedule
# rather than pushed by an event. **No new credential**, which `#124` requires:
# both repositories are public and their Actions runs answer an unauthenticated
# `GET`. The token is passed when there is one, so the run does not spend from
# the anonymous rate limit on a runner that has a better one.
#
# ## Why two failures and not one, and not three
#
# One failure is noise — a runner hiccup, a transient SSH refusal, a registry
# timeout. **Two in a row is a pipeline that is not working**, because the second
# run started after the first had finished and hit the same wall.
#
# The number is set against the incident rather than against taste. At two, this
# fires on the second run — roughly forty minutes into that outage rather than
# sixteen hours. At one it would have been right that morning and would also fire
# on every flake forever, which is how an alert channel gets muted. At three it
# buys nothing the second run has not already proved.
#
# `CONSECUTIVE_FAILURES` overrides it, which is what the rehearsal drives.
#
# ## What it counts, and the two things that are deliberately not counted
#
# **Only `main`, and only completed runs.** A branch's deploy failing is that
# branch's problem; a run still in progress has no conclusion to count and must
# not reset the streak either — it is not yet evidence in either direction.
#
# **`cancelled` and `skipped` break the streak without extending it.** Somebody
# cancelling a superseded deploy is not a failing pipeline, and treating it as a
# success would be worse: it would end a real streak that is still running.
set -uo pipefail

REPOS="${DEPLOY_ALARM_REPOS:-Kolonie-AI/kolonie-platform:build-and-deploy.yml Kolonie-AI/kolonie-infra:deploy.yml}"
THRESHOLD="${CONSECUTIVE_FAILURES:-2}"
API="${GITHUB_API_URL:-https://api.github.com}"
BRANCH="${DEPLOY_ALARM_BRANCH:-main}"

api_get() {
  local url=$1
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -sS --max-time 30 -H "Authorization: Bearer $GH_TOKEN" \
      -H 'Accept: application/vnd.github+json' "$url"
  else
    curl -sS --max-time 30 -H 'Accept: application/vnd.github+json' "$url"
  fi
}

# The streak, newest run first. Stops at the first run that is not a failure, so
# a success anywhere in the list ends the count — which is the definition of
# *consecutive* and is why this cannot be a `select(.conclusion=="failure")|length`.
#
# Prints: <count>\t<first failing run's url>\t<first failing run's created_at>\t<title>
# where *first* means the oldest run in the current streak, because "since when"
# is the question a reader asks first and the one `#123` could not answer.
streak_for() {
  local repo=$1 workflow=$2 body
  body=$(api_get "$API/repos/$repo/actions/workflows/$workflow/runs?branch=$BRANCH&status=completed&per_page=30")

  # An error object, an empty answer or a rate limit must not read as zero
  # failures. Silence here would mean the alarm is off and nothing says so.
  if ! printf '%s' "$body" | jq -e '.workflow_runs | type == "array"' >/dev/null 2>&1; then
    printf 'unreadable\t%s\t\t%s\n' "$repo" \
      "$(printf '%s' "$body" | jq -r '.message // "no answer"' 2>/dev/null || echo 'no answer')"
    return
  fi

  # The API answers newest first. The streak is the run of leading failures, so
  # the count is the index of the first conclusion that is not one — and the
  # whole list when there is none.
  printf '%s' "$body" | jq -r '
    [.workflow_runs[]
     | select(.conclusion != null)
     | {c: .conclusion, url: .html_url, at: .created_at, title: .display_title}]
    as $runs
    | ([$runs[].c]
       | (. as $c | first(range(0; length) | select($c[.] != "failure")) // length)) as $count
    | if $count == 0 then "0\t\t\t"
      else ($runs[$count - 1]) as $oldest
           | "\($count)\t\($oldest.url)\t\($oldest.at)\t\($oldest.title)"
      end'
}

cmd_check() {
  local report=${1:-/dev/stdout} any=0 unreadable=0
  : > "$report"

  local entry repo workflow line count url at title
  for entry in $REPOS; do
    repo=${entry%%:*}
    workflow=${entry##*:}
    line=$(streak_for "$repo" "$workflow")
    IFS=$'\t' read -r count url at title <<<"$line"

    if [ "$count" = unreadable ]; then
      # Reported rather than swallowed, and it does not raise the alarm on its
      # own: an unreachable API says nothing about whether deploys are working,
      # and filing *the deploy is broken* because GitHub was slow is the wrong
      # claim. It goes in the report so a reader can see the answer is partial.
      printf 'unreadable\t%s\t%s\t%s\n' "$url" "" "$title" >> "$report"
      unreadable=1
      continue
    fi

    if [ "${count:-0}" -ge "$THRESHOLD" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$count" "$url" "$at" "$title" >> "$report"
      any=1
    fi
  done

  [ "$unreadable" = 1 ] && echo "at least one repository could not be read — the answer is partial" >&2
  [ "$any" = 1 ] && return 1
  return 0
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  *) echo "usage: $0 check <report-file>" >&2; exit 2 ;;
esac
