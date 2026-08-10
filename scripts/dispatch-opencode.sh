#!/bin/bash
# Kolonie AI — start the coding worker, because GitHub's own schedule does not
# (kolonie-docs#142, kolonie-infra#111).
#
# ## Why this exists
#
# `opencode-worker.yml` carries a `schedule:` block and GitHub honours very
# little of it. Measured across the night of 2026-08-09:
#
#   cron          window            runs started
#   20,50         20:12 – 23:51     6   (of 8 due)
#   */10          00:00 – 03:20     1   (of 20 due)
#
# **Three times the triggers produced a sixth of the runs.** It is not this
# repository's workflow either: `health-watch.yml`, on `*/15` in this same
# organisation, went from 00:35 to 02:59 without firing once. GitHub delays
# scheduled runs under load and drops them outright, and says so.
#
# A `workflow_dispatch` is not rationed the same way. Every manual dispatch on
# 2026-08-09 started within seconds, including the one that proved this script's
# call before it was written.
#
# So the cadence moves to a host that keeps time. `kolonie-payments-reconcile`
# has fired on the quarter hour all night on this box while GitHub was dropping
# runs three repositories over.
#
# ## What it does not do
#
# **It does not decide anything.** The workflow still reads the board, still
# takes at most one issue, and still exits early if a run is already going —
# `Am I already running?` is what makes a duplicate dispatch harmless, and it is
# why this script can be simple and why the `schedule:` block can stay as a
# fallback for a night when this host is down.
#
# **It does not know what the worker will do.** No issue number, no repository,
# no filter. Everything about which issue is next lives in the queue, where two
# people can read it.
#
# Usage, on the deploy host:
#
#   ./scripts/dispatch-opencode.sh
#
# Needs `OPENCODE_DISPATCH_TOKEN` in /opt/kolonie/.env — a GitHub token that may
# write Actions on `Kolonie-AI/kolonie-docs` and wants no other power.
set -uo pipefail

DEPLOY_DIR="${KOLONIE_DEPLOY_DIR:-/opt/kolonie}"
REPO="${OPENCODE_REPO:-Kolonie-AI/kolonie-docs}"
WORKFLOW="${OPENCODE_WORKFLOW:-opencode-worker.yml}"
REF="${OPENCODE_REF:-main}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Read in a subshell so a file of `NAME=value` lines cannot overwrite anything
# above — `deployed-revision.sh`'s rule, and for the same reason.
token=$(
    set +u
    # shellcheck disable=SC1091
    . "$DEPLOY_DIR/.env" 2>/dev/null
    printf '%s' "${OPENCODE_DISPATCH_TOKEN:-}"
)

if [ -z "$token" ]; then
    log "OPENCODE_DISPATCH_TOKEN is not set in $DEPLOY_DIR/.env — nothing dispatched."
    exit 1
fi

# `--fail-with-body` would print the body on an error and the body of a GitHub
# error names the repository and the workflow. The status is enough to act on and
# the body is not worth putting in a journal that is read over somebody's
# shoulder.
status=$(
    curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 20 \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
        -d "{\"ref\":\"${REF}\"}" 2>/dev/null
)

case "$status" in
    204)
        log "dispatched ${REPO} ${WORKFLOW} on ${REF}"
        ;;
    401 | 403)
        # Worth separating from the rest: this one does not fix itself and every
        # later pass will say the same thing.
        log "ERROR: GitHub refused the token ($status). It needs Actions: write on ${REPO}."
        exit 1
        ;;
    "")
        log "ERROR: no answer from GitHub within the timeout. The next pass will try again."
        exit 1
        ;;
    *)
        log "ERROR: GitHub answered $status. The next pass will try again."
        exit 1
        ;;
esac
