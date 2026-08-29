#!/bin/bash
# This repository's own check command. `AGENTS.md` → *The check command*.
#
# Usage: bash scripts/check.sh
#
# ## Why this exists when §6 already lists the commands
#
# §6 lists four; §7's definition of done requires two of them conditionally. That
# is a procedure, and a procedure is something a person follows and an agent
# guesses at. Every other repository in the organisation answers *what do I run
# before committing* with one command.
#
# `kolonie-docs#231` is what forced it: the hourly coding worker now works issues
# in any repository and runs **that repository's** check before opening a pull
# request, reading which one out of its `AGENTS.md`. A repository naming none
# stops the run. This one named four.
#
# ## What it runs, and what it deliberately does not
#
# The rehearsal tests run anywhere, with no Docker,
# no VPS and no credentials, which is the property `AGENTS.md` §6 makes a point
# of and the only reason a check command is possible here at all.
#
# **`env-drift.sh` is not here.** §6 lists it, and it is the one that only means
# anything *on the host* — it compares against a live `.env` that does not exist
# on a runner or a laptop. A check that cannot fail honestly is worse than one
# that is missing, because it makes the list look answered (`kolonie-docs#124`).
#
# `check-log-levels.sh` runs: it is a fixture-driven test of the promtail
# derivation and needs nothing but the file.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILED=()

# Every `rehearse-*.sh` is named above. Written as a check rather than as a loop
# so that a rehearsal can still be left out on purpose — but only in writing.
#
# It is the gap that let `rehearse-pin.sh` go red on `main`: `.github/workflows/
# rehearse.yml` ran it, this file did not, and the check command a contributor is
# told to run before pushing was green on a change that broke it.
every_rehearsal_is_run() {
  local missing=() f name
  for f in scripts/rehearse-*.sh; do
    name=$(basename "$f")
    grep -qF "scripts/$name" "$0" || missing+=("$name")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "   not run by this file: ${missing[*]}"
  return 1
}

step() {
  local what=$1
  shift
  echo
  echo "── $what"
  if "$@"; then
    echo "   ok"
  else
    echo "   FAILED"
    FAILED+=("$what")
  fi
}

step "deploy.sh, against a stub docker" bash scripts/rehearse-deploy.sh
step "backup.sh, against a stub docker" bash scripts/rehearse-backup.sh
step "image-prune.sh, against a stub docker" bash scripts/rehearse-image-prune.sh
step "the service list against compose" bash scripts/check-services.sh
step "a primary gateway also receives the fallback pair" bash scripts/check-gateway-fallback.sh
step "deployed-revision.sh, against a stub docker" bash scripts/rehearse-deployed-revision.sh
step "drift-triage.sh" bash scripts/rehearse-drift.sh
step "the health watcher's own wiring" bash scripts/rehearse-watch-wiring.sh
step "what reaches the step output as a verdict" bash scripts/rehearse-verdict-out.sh
step "the promtail level derivation" bash scripts/check-log-levels.sh
step "the host resource alarms" bash scripts/rehearse-host-resources.sh
step "the deploy alarm's counting rules" bash scripts/rehearse-deploy-alarm.sh
step "what the host publishes as resource pressure" bash scripts/rehearse-pressure.sh
step "the unit-drift rows" bash scripts/rehearse-unit-drift.sh
step "a container left behind by a recreate" bash scripts/rehearse-recreate-leftover.sh
step "the timer rows, and the window a running service opens in them" bash scripts/rehearse-timer-window.sh
step "the pin check, against a stub docker" bash scripts/rehearse-pin.sh
step "code-drift.sh" bash scripts/rehearse-code-drift.sh
step "the Twilio balance alarm" bash scripts/rehearse-twilio-balance.sh
step "every timer schedules from a calendar" bash scripts/check-timers.sh
step "what the apex host's routers promise each other" bash scripts/check-routes.sh
step "the deploy filter §8 quotes" bash scripts/check-deploy-paths.sh
step "every rehearsal is run by this file" every_rehearsal_is_run

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "all good"
  exit 0
fi
echo "${#FAILED[@]} failed:"
printf '  - %s\n' "${FAILED[@]}"
exit 1
