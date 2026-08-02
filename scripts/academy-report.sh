#!/bin/bash
# Kolonie AI — is the Academy actually being completed? (kolonie-docs#21)
#
# **"Which task does everyone fail?" is a product question, and it is answerable
# with a SQL query over `submissions` long before it needs a dashboard.** That is
# what `kolonie-docs#21` decided, and this is the query. If it ever gets run often
# enough to be annoying, that is the signal to build the dashboard — not before.
#
# It prints two things and nothing else:
#
#   1. a row per task type: submissions, passed, failed, still open, distinct
#      agents, and the pass rate
#   2. the tasks with no submissions at all, which is the other half of the same
#      question — a rung nobody reaches looks identical to a rung nobody fails
#
# **Reads only.** No writes, no temporary tables, no transactions left open. Safe
# to run against production, which is where it is useful, because the interesting
# rows only exist there.
#
# ## Why a row per task *type* and not per task id
#
# A task's text is revised in place and its id survives, so the id answers "which
# row in the table" and the type answers "which rung of the Academy". The second
# is the question. `text_revised_at` is on `tasks` if a revision ever needs to be
# correlated with a change in pass rate — that is a real follow-up and this script
# deliberately does not pre-empt it.
#
# ## What a low pass rate means, and what it does not
#
# It is a starting point for a look, not a verdict. A rung can be hard on purpose.
# What the number is good for is **noticing** — `image-gen` sat at 2 passes in 12
# submissions on 2026-08-02, and `kolonie-platform#208` (failed submissions carry
# no reason) was already open against exactly that task. One of those two facts
# explains the other, and neither was visible from the other's side.
#
# Usage, on the deploy host:
#
#   ./scripts/academy-report.sh
#
# Or from a workstation with ssh access:
#
#   ssh <host> 'bash -s' < scripts/academy-report.sh

set -euo pipefail

CONTAINER="${POSTGRES_CONTAINER:-kolonie-postgres}"
DB_USER="${POSTGRES_USER:-kolonie}"
DB_NAME="${POSTGRES_DB:-kolonie}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: no container named $CONTAINER on this host."
    echo "  This script reads the production database and has to run where it lives."
    exit 2
fi

# `docker exec -i`, and the -i is load-bearing. Without it stdin is not forwarded:
# psql receives nothing, prints nothing, and exits 0 — a heredoc sent that way is
# indistinguishable from a query that ran and matched no rows.
docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -P pager=off <<'SQL'
\echo '=== Academy: submissions per rung ==='
select t.type                                                        as task,
       t.status                                                      as state,
       count(s.id)                                                   as subs,
       count(*) filter (where s.status = 'passed')                   as passed,
       count(*) filter (where s.status = 'failed')                   as failed,
       count(*) filter (where s.status in ('pending', 'verifying'))  as still_open,
       count(distinct s.agent_id)                                    as agents,
       case
         when count(*) filter (where s.status in ('passed', 'failed')) = 0 then null
         else round(
           100.0 * count(*) filter (where s.status = 'passed')
                 / count(*) filter (where s.status in ('passed', 'failed')))
       end                                                           as pass_pct
from tasks t
     left join submissions s on s.task_id = t.id
group by t.type, t.status
having count(s.id) > 0
order by pass_pct nulls last, subs desc;

\echo ''
\echo '=== Active rungs nobody has submitted to ==='
\echo '(a rung nobody reaches looks the same as one nobody fails, from the other query)'
select t.type as task, t.status as state
from tasks t
where not exists (select 1 from submissions s where s.task_id = t.id)
  and t.status = 'active'
order by t.type;
SQL
