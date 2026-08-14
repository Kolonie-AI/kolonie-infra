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
    # nginx's *error* log, which is a different shape from its access log and so
    # matched nothing until #97. 942 lines a day arrived unlabelled this way.
    ('website', '2026/08/09 04:12:07 [notice] 1#1: gracefully shutting down'),
    ('website', '2026/08/09 04:12:07 [warn] 31#31: conflicting server name'),
    ('website', '2026/08/09 04:12:07 [emerg] 1#1: bind() to 0.0.0.0:80 failed (98: Address in use)'),
    # A missing static file, which nginx writes to *both* streams: a 404 to the
    # access log and this to the error log. 5b calls the first `info` and 5c
    # called this `error`, so one person typing produced a 56-error spike
    # (`#166`). The first is the real line from that window, apostrophe and all.
    ('website', '2026/08/09 04:12:07 [error] 31#31: *268 open() "/usr/share/nginx/html/_astro/theme.Cm3PO5O0.css\'" failed (2: No such file or directory), client: 2001:db8::1, server: kolonie.ai, request: "GET /_astro/theme.Cm3PO5O0.css\' HTTP/2.0"'),
    ('website', '2026/08/09 04:12:07 [error] 31#31: *269 stat() "/usr/share/nginx/html/missing" failed (2: No such file or directory), client: 2001:db8::1'),
    # The rejection cases for that narrowing, asserted rather than assumed: a
    # different errno is the *server* being wrong, and an upstream failure is
    # not an `open()` at all. Both must survive at `error`.
    ('website', '2026/08/09 04:12:07 [error] 31#31: *270 open() "/usr/share/nginx/html/locked.css" failed (13: Permission denied), client: 2001:db8::1'),
    ('website', '2026/08/09 04:12:07 [error] 31#31: *271 connect() failed (111: Connection refused) while connecting to upstream'),
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

# **Asserted, not eyeballed** (`#97`). This printed its output under a heading
# reading "What to look for" and exited 0 whatever the pipeline had done — so a
# derivation that silently stopped matching would have produced a green run and a
# list nobody compared against anything. `#97` names that exactly: *what is
# missing is the measurement that would have said so*.
$DOCKER run --rm -i -v "$WORK:/w" "$PROMTAIL_IMAGE" \
  -config.file=/w/promtail.yml -stdin -dry-run < "$WORK/sample.log" 2>/dev/null |
  grep 'job=' | sed -E 's/^[0-9T:+-]+//' > "$WORK/labelled.txt"

cat "$WORK/labelled.txt" | cut -c1-160
echo

FAILED=()

# `<service> <expected-level> <a substring of the line>`. An expected level of
# `-` means the line must arrive with **no** level: some genuinely cannot have
# one, and asserting that is as much the point as asserting the ones that can.
# `DROPPED` means the line must not arrive at all.
assert_level() {
  local service=$1 expected=$2 needle=$3
  local line
  # `|| true`, and it is load-bearing: this file runs under `set -e -o pipefail`,
  # and a `grep` that finds nothing is the *expected* result for every DROPPED
  # assertion. Without it the script exits silently at the first such line and
  # reports success by never reaching the failure count.
  line=$(grep -F "$needle" "$WORK/labelled.txt" | head -1 || true)

  if [ "$expected" = DROPPED ]; then
    if [ -z "$line" ]; then echo "  ok   dropped: $needle"
    else echo "  FAIL survived but should have been dropped: $needle"; FAILED+=("$needle"); fi
    return
  fi

  if [ -z "$line" ]; then
    echo "  FAIL missing entirely: $needle"
    FAILED+=("$needle")
    return
  fi

  local got
  got=$(sed -E 's/.*level="?([a-z]*)"?.*/\1/' <<<"$line")
  grep -q 'level=' <<<"$line" || got=""

  if [ "$expected" = - ]; then
    if [ -z "$got" ]; then echo "  ok   no level, correctly: $needle"
    else echo "  FAIL got level=$got, expected none: $needle"; FAILED+=("$needle"); fi
  elif [ "$got" = "$expected" ]; then
    echo "  ok   level=$expected: $needle"
  else
    echo "  FAIL got level=${got:-none}, expected $expected: $needle"
    FAILED+=("$needle")
  fi
}

echo "postgres — its own severity, and a human at a prompt told apart"
assert_level postgres info        'checkpoint starting'
assert_level postgres error       'relation "verdicts" does not exist'
assert_level postgres interactive 'syntax error at or near'
assert_level postgres warn        'something mild'

echo
echo "the edge — 5xx is an error, 4xx and 2xx are not"
assert_level traefik info  '"POST / HTTP/2.0" 200'
assert_level traefik error '"GET /v1/x HTTP/2.0" 502'
assert_level traefik error 'something at the edge'
assert_level website error '"GET / HTTP/1.1" 500'
assert_level pgadmin info  '/misc/ping'

echo
echo "nginx's error log, which is not its access log (#97)"
assert_level website info  'gracefully shutting down'
assert_level website warn  'conflicting server name'
assert_level website error 'bind() to 0.0.0.0:80 failed'

echo
echo "a missing static file is the client being wrong, on either stream (#166)"
# The event 5b already counts as `info` from the access log. It must not arrive
# a second time as `error` from the error log — that double count is what made
# `website` the loudest service in the Watch Agent's error table.
assert_level website info  'theme.Cm3PO5O0.css'
assert_level website info  'stat() "/usr/share/nginx/html/missing"'
# **Rejection cases.** The narrowing is by errno, not by syscall: a permission
# denial is the server being wrong, and an upstream refusal is not an `open()`.
# Neither may be swept up with the missing files.
assert_level website error 'Permission denied'
assert_level website error 'Connection refused'

echo
echo "a service that already says so keeps what it said"
assert_level api info 'a service that already says so'

echo
echo "the observability stack: chatter dropped, warnings kept (#81)"
assert_level loki     DROPPED 'no marks file found'
assert_level promtail DROPPED 'received file watcher event'
assert_level loki     warn    'refusing writes'
assert_level loki     -       'panic: runtime error'

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "all good"
  exit 0
fi
echo "${#FAILED[@]} failed:"
printf '  - %s\n' "${FAILED[@]}"
exit 1
