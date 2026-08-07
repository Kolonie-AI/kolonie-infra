#!/bin/bash
# Rehearse code-drift.sh without a kolonie-platform checkout (#90).
#
# Usage: ./scripts/rehearse-code-drift.sh
#
# The check's whole value is in two properties, and both are ones a real run
# against today's tree cannot demonstrate — because today's tree is clean, which
# is the point of having installed it:
#
#   1. **It resolves `process.env[SOME_CONST]`.** A version matching only string
#      literals would report zero problems and be *worse than nothing*, because
#      it would look like coverage. Asserted against a fixture shaped exactly
#      like `MASTODON_VERIFIER_INSTANCES`.
#   2. **It excludes test files by path.** Asserted against a fixture shaped like
#      `MCP_SURFACE_REPORT`, which lives only in a `.test.ts` and must not be
#      reported.
#   3. **It reads `env[...]` off an alias, not only `process.env[...]`.** The
#      environment is routinely a parameter — `mailerFromEnv(env = process.env)`
#      — and measured 2026-08-07 more names are read that way than directly. The
#      `process.env`-only version reported a clean tree while being blind to most
#      of it, which is property 1's failure wearing a different shape. Caught by
#      `MAIL_SENDER_NAME` reaching nothing while the check said OK.
#
# So the fixtures are a scratch tree laid out like a platform checkout, and a
# scratch compose file. Neither needs Docker, a host, a network or a credential.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

# --- the fixture tree --------------------------------------------------------
# Laid out as `apps/<service>/src` and `packages/<lib>/src`, because the check
# looks for reads in the first and constant *definitions* in both.
platform() {
    rm -rf "$WORK/platform"
    mkdir -p "$WORK/platform/apps/api/src" \
             "$WORK/platform/apps/api/src/mcp" \
             "$WORK/platform/packages/verifiers/src"
}

compose_with() {
    {
        echo 'services:'
        echo '  api:'
        echo '    environment:'
        for name in "$@"; do
            printf '      %s: ${%s:-}\n' "$name" "HOST_$name"
        done
    } > "$WORK/compose.yml"
}

drift() {
    COMPOSE_FILE="$WORK/compose.yml" ALLOW_FILE="$WORK/allow" \
        bash "$ROOT/scripts/code-drift.sh" "$WORK/platform" 2>&1
}

: > "$WORK/allow"

echo "== 1. a literal read that compose does not pass is reported, and fails"
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const colonyNumber = process.env['SMS_COLONY_NUMBER']
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1" "$status" "1"
contains "$out" "SMS_COLONY_NUMBER" "named the inert variable"
contains "$out" "DRIFT" "said so plainly"

echo "== 2. the same name, passed by compose, is not reported"
compose_with DATABASE_URL SMS_COLONY_NUMBER
out=$(drift); status=$?
check "exit 0" "$status" "0"
absent "$out" "SMS_COLONY_NUMBER" "nothing to report"
contains "$out" "OK" "said so"

echo "== 3. the indirection case — the one a literal-only check cannot see"
# `#90`: *a version of this check that only matched string literals would report
# zero problems and be worse than nothing.* This is that assertion.
platform
cat > "$WORK/platform/packages/verifiers/src/mastodon.ts" <<'TS'
export const MASTODON_INSTANCES_VAR = 'MASTODON_VERIFIER_INSTANCES'
TS
cat > "$WORK/platform/apps/api/src/runner.ts" <<'TS'
import { MASTODON_INSTANCES_VAR } from '@kolonie-ai/verifiers'
const instances = process.env[MASTODON_INSTANCES_VAR]
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1" "$status" "1"
contains "$out" "MASTODON_VERIFIER_INSTANCES" "resolved the constant to the name it holds"
absent "$out" "MASTODON_INSTANCES_VAR" "and reported the variable, not the identifier"

echo "== 4. a test-only variable is never reported"
# The one false positive writing this measurement by hand produced, because the
# filter ran over `grep -o` output that carries no filename.
platform
cat > "$WORK/platform/apps/api/src/mcp/surface-size.test.ts" <<'TS'
const report = process.env['MCP_SURFACE_REPORT']
TS
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const url = process.env['DATABASE_URL']
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 0" "$status" "0"
absent "$out" "MCP_SURFACE_REPORT" "the test's variable is not a production gap"

echo "== 5. an in-code default is reported without failing"
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const port = Number(process.env['HEALTH_PORT'] ?? 3003)
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 0 — HEALTH_PORT is not noise" "$status" "0"
contains "$out" "HEALTH_PORT" "still listed, so a reader can tell the two apart"
contains "$out" "OK" "and did not fail the run"

echo "== 6. a fallback to the empty string is NOT a default"
# `#480` is exactly this shape: the `??` is there and what it falls back to is
# *unconfigured*, so the guard refused every call from the day it shipped.
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const colonyNumber = process.env['SMS_COLONY_NUMBER'] ?? ''
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1" "$status" "1"
contains "$out" "SMS_COLONY_NUMBER" "reported as inert rather than defaulted"

echo "== 7. compose passing it under another host name still counts"
# `OPENROUTER_API_KEY: ${OPENROUTER_API_KEY_MODERATION:-}` — the container gets
# the left-hand name. Reading the right-hand side reported four names as inert
# that compose passes perfectly well.
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const key = process.env['OPENROUTER_API_KEY'] ?? ''
TS
{
    echo 'services:'
    echo '  api:'
    echo '    environment:'
    echo '      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY_MODERATION:-}'
} > "$WORK/compose.yml"
out=$(drift); status=$?
check "exit 0" "$status" "0"
absent "$out" "OPENROUTER_API_KEY_MODERATION" "did not confuse the host name for the container's"

echo "== 8. a runtime identifier is named as a hole, not resolved to nonsense"
# `process.env[name]`, where `name` is a parameter. Resolving it anyway invented
# two variables on 2026-08-07.
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const missing = (name: string) => (process.env[name] ?? '') === ''
const label = 'viewport'
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 0 — a hole it can name is not a finding about the code" "$status" "0"
contains "$out" "runtime value rather than a name" "said what it could not see"
absent "$out" "viewport" "and did not invent a variable"

echo "== 9. an unresolvable constant is loud rather than silent"
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const value = process.env[SOME_NAME_VAR]
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1 — a hole in the check is a failure of the check" "$status" "1"
contains "$out" "SOME_NAME_VAR" "named the identifier it could not resolve"
contains "$out" "hole in the check itself" "and said whose fault it is"

echo "== 10. the allow file excuses a name, and only where it says so"
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const model = classify(process.env[DIRECTION_MODEL_VAR])
TS
cat > "$WORK/platform/packages/verifiers/src/direction.ts" <<'TS'
export const DIRECTION_MODEL_VAR = 'DIRECTION_MODEL'
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1 before it is allowed" "$status" "1"

echo 'DIRECTION_MODEL  the default is applied by the callee' > "$WORK/allow"
out=$(drift); status=$?
check "exit 0 after" "$status" "0"
contains "$out" "DIRECTION_MODEL" "still listed as deliberate"

echo "== 11. it sees a read through an aliased env parameter"
# `mailerFromEnv(env = process.env)` then `env[MAIL_SENDER_NAME_VAR]`. Measured
# 2026-08-07: **more names are read that way than directly**, so the
# `process.env`-only version was blind to most of the surface while reporting a
# clean result — which is the failure this whole script exists not to be. Caught
# by `MAIL_SENDER_NAME` (kolonie-platform#483) reaching nothing while this said
# OK.
platform
cat > "$WORK/platform/apps/api/src/mail.ts" <<'TS'
export const MAIL_SENDER_NAME_VAR = 'MAIL_SENDER_NAME'
export function mailerFromEnv(env: NodeJS.ProcessEnv = process.env) {
  return env[MAIL_SENDER_NAME_VAR]
}
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1" "$status" "1"
contains "$out" "MAIL_SENDER_NAME" "resolved it through the alias and the constant both"

echo "== 11b. and a literal read off an alias"
platform
cat > "$WORK/platform/apps/api/src/mail.ts" <<'TS'
export function build(env: NodeJS.ProcessEnv = process.env) {
  return env['ACADEMY_SENDER_ADDRESS']
}
TS
compose_with DATABASE_URL
out=$(drift); status=$?
check "exit 1" "$status" "1"
contains "$out" "ACADEMY_SENDER_ADDRESS" "named it"

echo "== 12. it refuses a path that is not a platform checkout"
out=$(COMPOSE_FILE="$WORK/compose.yml" bash "$ROOT/scripts/code-drift.sh" "$WORK/nowhere" 2>&1); status=$?
check "exit 1" "$status" "1"
contains "$out" "does not look like a kolonie-platform checkout" "said why"

echo "== 13. it never prints a value"
# The names are the deliverable. This runs in workflows whose logs are public.
platform
cat > "$WORK/platform/apps/api/src/server.ts" <<'TS'
const secret = process.env['A_SECRET'] ?? 'the-actual-secret-value'
TS
compose_with DATABASE_URL
out=$(drift)
absent "$out" "the-actual-secret-value" "no value reached the output"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
