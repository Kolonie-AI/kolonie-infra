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
step "deployed-revision.sh, against a stub docker" bash scripts/rehearse-deployed-revision.sh
step "drift-triage.sh" bash scripts/rehearse-drift.sh
step "the health watcher's own wiring" bash scripts/rehearse-watch-wiring.sh
step "the promtail level derivation" bash scripts/check-log-levels.sh
step "the host resource alarms" bash scripts/rehearse-host-resources.sh

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "all good"
  exit 0
fi
echo "${#FAILED[@]} failed:"
printf '  - %s\n' "${FAILED[@]}"
exit 1
