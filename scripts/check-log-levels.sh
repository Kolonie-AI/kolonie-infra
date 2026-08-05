#!/bin/bash
# Kolonie AI — what the log pipeline labels, and what it throws away (#80, #81)
#
# Usage:
#   ./scripts/check-log-levels.sh          run the fixtures through the real pipeline
#
# ## What this is for
#
# Six of eleven services never emitted a `level`, so they could not report a
# failure to anything that filters on one — and every query the Watch Agent makes
# filters on it. `promtail/promtail.yml` now derives a level for them. This runs
# that pipeline, unmodified, over one line of every shape that matters and prints
# the label it produced.
#
# It is also where the drop is checked (`#81`). Loki and Promtail wrote 42 % of
# everything stored, describing themselves; their chatter is dropped at ingestion
# and their warnings are not. **A line that is absent from this output was
# dropped, and a line that is present survived** — which is the cheapest way to
# see that the drop is narrow rather than to assume it.
#
# **It is a check somebody runs by hand, not a CI job.** This repository's `CI` is
# parse-only by charter and says so at length; this needs Docker and a network
# pull, which is exactly the kind of thing that charter keeps out. Run it after
# touching the pipeline, before deploying it.
#
# ## The case worth reading
#
# The 26 postgres errors in the logs over 24 hours to 2026-08-05 were all
# maintainers and agents typing at a `psql` prompt against production. The
# fixtures below contain one of those and one real application error, and the
# check is that they come out differently: `interactive` and `error`. A pipeline
# that labelled both `error` would turn every typo into an incident, and a
# watcher that cries wolf is a watcher nobody reads.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMTAIL_IMAGE="${PROMTAIL_IMAGE:-grafana/promtail:3.0.0}"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  # The host runs this as a user in the docker group; a workstation may not be.
  DOCKER="sudo -n docker"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The pipeline, lifted out of the real file so this cannot drift from it, with a
# stdin target in place of the Docker log directory.
python3 - "$HERE/promtail/promtail.yml" "$WORK/promtail.yml" <<'PY'
import sys, yaml

source, destination = sys.argv[1], sys.argv[2]
stages = yaml.safe_load(open(source))['scrape_configs'][0]['pipeline_stages']

yaml.safe_dump(
    {
        'server': {'http_listen_port': 0, 'grpc_listen_port': 0},
        'positions': {'filename': '/tmp/positions.yaml'},
        'clients': [{'url': 'http://localhost:3100/loki/api/v1/push'}],
        'scrape_configs': [
            {
                'job_name': 'containers',
                'static_configs': [{'targets': ['localhost'], 'labels': {'job': 'containers'}}],
                'pipeline_stages': stages,
            }
        ],
    },
    open(destination, 'w'),
    sort_keys=False,
)
PY

# One line of each shape, wrapped in Docker's json-file envelope exactly as
# Promtail reads it off disk. The service name arrives the way it does in
# production: a container label the json-file driver copies onto every line.
python3 - "$WORK/sample.log" <<'PY'
import json, sys

cases = [
    ('postgres', '2026-08-05 15:08:37.108 UTC [28] LOG:  checkpoint starting: time'),
    ('postgres', '2026-08-05 15:08:37.108 UTC [55] kolonie@kolonie/ ERROR:  relation "verdicts" does not exist at character 130'),
    ('postgres', '2026-08-05 15:08:37.108 UTC [56] kolonie@kolonie/psql ERROR:  syntax error at or near "\\\\" at character 87'),
    ('postgres', '2026-08-05 15:08:37.108 UTC [57] kolonie@kolonie/ WARNING:  something mild'),
    ('traefik', '95.89.46.52 - - [05/Aug/2026:15:17:06 +0000] "POST / HTTP/2.0" 200 148937 "-" "-" 15210 "mcp@file" "http://kolonie-api:3000" 534ms'),
    ('traefik', '95.89.46.52 - - [05/Aug/2026:15:17:06 +0000] "GET /v1/x HTTP/2.0" 502 0 "-" "-" 15211 "api@file" "http://kolonie-api:3000" 12ms'),
    ('traefik', 'time="2026-08-05T15:17:06Z" level=error msg="something at the edge"'),
    ('website', '127.0.0.1 - - [05/Aug/2026:15:20:25 +0000] "GET / HTTP/1.1" 500 41518 "-" "Wget" "-"'),
    ('pgadmin', '::ffff:127.0.0.1 - - [05/Aug/2026:15:21:47 +0000] "GET /misc/ping HTTP/1.1" 200 4 "-" "Wget"'),
    ('api', '{"level":"info","time":1785900000000,"msg":"a service that already says so"}'),
    # The observability stack (#81): the chatter goes, a warning stays, and a
    # line with no parseable level stays too.
    ('loki', 'level=info ts=2026-08-05T15:26:13.688203605Z caller=marker.go:202 msg="no marks file found"'),
    ('promtail', 'level=info ts=2026-08-05T15:26:23.342380237Z caller=filetargetmanager.go:193 msg="received file watcher event"'),
    ('loki', 'level=warn ts=2026-08-05T15:26:13.688203605Z caller=ingester.go:1 msg="refusing writes"'),
    ('loki', 'panic: runtime error: invalid memory address'),
]

with open(sys.argv[1], 'w') as out:
    for service, line in cases:
        out.write(
            json.dumps(
                {
                    'log': line + '\n',
                    'stream': 'stdout',
                    'attrs': {'com.docker.compose.service': service},
                    'time': '2026-08-05T15:17:06.000000000Z',
                }
            )
            + '\n'
        )
PY

echo "Running ${PROMTAIL_IMAGE} over $(wc -l < "$WORK/sample.log") fixture lines…"
echo

$DOCKER run --rm -i -v "$WORK:/w" "$PROMTAIL_IMAGE" \
  -config.file=/w/promtail.yml -stdin -dry-run < "$WORK/sample.log" 2>/dev/null |
  grep 'job=' |
  sed -E 's/^[0-9T:+-]+//' |
  cut -c1-160

echo
echo "What to look for:"
echo "  · every line carries a level="
echo "  · the psql ERROR is level=\"interactive\", not level=\"error\""
echo "  · the application ERROR beside it is level=\"error\""
echo "  · the 502 and the 500 are errors; the 200s are not"
echo "  · the api line, which already said info, still says info"
echo "  · loki's and promtail's info lines are absent — dropped at ingestion (#81)"
echo "  · loki's warn line is present, and labelled, so a Loki refusing writes can say so"
echo "  · loki's panic line is present: an unparseable level is kept, not dropped"
