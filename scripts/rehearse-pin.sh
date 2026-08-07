#!/bin/bash
# Rehearse the pin check without Docker, a host or a network (#89).
#
# Usage: ./scripts/rehearse-pin.sh
#
# Two scripts are under test and they fail in different ways, so both are here.
#
# `pin-report.sh` reads a real `deployed.env` and asks Docker two questions per
# service. Its interesting behaviour is what it does when an answer is missing —
# no record, no image, no container — because those are the states a real host
# spends most of its time in and the ones a guess would paper over.
#
# `pin-triage.sh` holds the judgement, and the judgement is the part worth
# testing: `drifted`, `absent` and `unknown` have to stay three different
# answers. Collapsing `absent` into `drifted` files a second issue for a fault
# Health Watch already owns; collapsing `unknown` into `ok` is a blind check
# reporting a clean host, which is the exact silence #89 was filed about.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
DEPLOY="$WORK/deploy"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN" "$DEPLOY/state"

# --- the stub -------------------------------------------------------------
# Two calls are made per service and they answer from two tables, keyed by the
# argument, so a test can make the record resolvable while the container is
# absent and every other combination. `MISSING` is a list of references and
# containers the stub refuses, which is how "not in the image store" and "not
# running" are expressed.
cat > "$BIN/docker" <<'STUB'
#!/bin/bash
# `docker info` decides whether the caller reaches for sudo. Answering yes keeps
# the rehearsal on one path; the sudo branch is one line and needs a host to be
# exercised honestly, so it is not pretended at here.
[ "${1:-}" = "info" ] && exit 0

want=""
for arg in "$@"; do
  case "$arg" in
    -*|inspect|image|--format|'{{.Id}}'|'{{.Image}}') ;;
    *) want="$arg" ;;
  esac
done

for m in ${MISSING:-}; do
  [ "$m" = "$want" ] && { echo "Error: No such object: $want" >&2; exit 1; }
done

# IDS is `key=value` pairs, whitespace separated: a reference or a container
# name, and the sha256 id it resolves to.
for pair in ${IDS:-}; do
  [ "${pair%%=*}" = "$want" ] && { printf '%s\n' "${pair#*=}"; exit 0; }
done

echo "Error: No such object: $want" >&2
exit 1
STUB
chmod +x "$BIN/docker"

A_REF="ghcr.io/kolonie-ai/kolonie-api@sha256:$(printf 'a%063d' 1 | tr ' ' '0')"
W_REF="ghcr.io/kolonie-ai/kolonie-website@sha256:$(printf 'w%063d' 1 | tr ' ' '0')"
GOOD="sha256:$(printf '1%063d' 0 | tr ' ' '1')"
OTHER="sha256:$(printf '2%063d' 0 | tr ' ' '2')"

write_state() {
    cat > "$DEPLOY/state/deployed.env" <<EOF
DEPLOYED_AT=20260807_101500
API_IMAGE=${A_REF}
WEBSITE_IMAGE=${W_REF}
EOF
}

report() {
    PATH="$BIN:$PATH" KOLONIE_DEPLOY_DIR="$DEPLOY" \
        env "$@" bash "$ROOT/scripts/pin-report.sh"
}

triage() { bash "$ROOT/scripts/pin-triage.sh"; }

pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

echo "== 1. a matching host: the record and the container agree"
write_state
out=$(report IDS="${A_REF}=${GOOD} kolonie-api=${GOOD} ${W_REF}=${GOOD} kolonie-website=${GOOD}" \
             MISSING="kolonie-verifier-runner kolonie-moderation-runner kolonie-support-triage-runner kolonie-badge-runner")
check "one row per service, upstream images excluded" "$(wc -l <<<"$out")" "6"
contains "$out" "api	${A_REF}	${GOOD}	${GOOD}" "api resolved on both sides"

verdict=$(triage <<<"$out" 2>&1 >/dev/null)
sum=$(triage <<<"$out" 2>/dev/null); status=$?
check "exit 0" "$status" "0"
contains "$verdict" "VERDICT=ok" "verdict ok"
contains "$sum" '| `api` | pinned |' "api reported as pinned"
contains "$sum" "4 service(s) are not running" "the four absent ones are counted apart"

echo "== 2. the 2026-08-06 failure: a container the record does not name"
out=$(report IDS="${A_REF}=${GOOD} kolonie-api=${OTHER} ${W_REF}=${GOOD} kolonie-website=${GOOD}" \
             MISSING="kolonie-verifier-runner kolonie-moderation-runner kolonie-support-triage-runner kolonie-badge-runner")
verdict=$(triage <<<"$out" 2>&1 >/dev/null)
sum=$(triage <<<"$out" 2>/dev/null); status=$?
check "exit 1 — the host, not the script" "$status" "1"
contains "$verdict" "VERDICT=drifted" "verdict drifted"
contains "$sum" '| `api` | drifted |' "api named as the one that disagrees"
contains "$sum" '| `website` | pinned |' "and website is still reported as pinned"
contains "$sum" "1 of 6 services" "counted rather than merely listed"

echo "== 3. a container that is not running is not drift"
# Health Watch already owns that fault and files its own issue for it. Two
# reports for one outage is how both get skimmed.
write_state
out=$(report IDS="${A_REF}=${GOOD} ${W_REF}=${GOOD} kolonie-website=${GOOD}" \
             MISSING="kolonie-api kolonie-verifier-runner kolonie-moderation-runner kolonie-support-triage-runner kolonie-badge-runner")
verdict=$(triage <<<"$out" 2>&1 >/dev/null)
sum=$(triage <<<"$out" 2>/dev/null); status=$?
check "exit 0 — an absent container is somebody else's verdict" "$status" "0"
contains "$verdict" "VERDICT=ok" "verdict stays ok"
contains "$sum" '| `api` | absent |' "api reported absent"
absent "$sum" '| `api` | drifted |' "and not reported as drifted"

echo "== 4. no deployed.env at all: unknown, and never ok"
rm -f "$DEPLOY/state/deployed.env"
out=$(report IDS="kolonie-api=${GOOD}" \
             MISSING="kolonie-verifier-runner kolonie-moderation-runner kolonie-support-triage-runner kolonie-badge-runner kolonie-website")
contains "$out" "api	-	-	${GOOD}" "the record answers nothing and the row says so"
verdict=$(triage <<<"$out" 2>&1 >/dev/null)
sum=$(triage <<<"$out" 2>/dev/null); status=$?
check "exit 1" "$status" "1"
contains "$verdict" "VERDICT=unknown" "verdict unknown, distinct from ok and from drifted"
contains "$sum" "names no image for this service" "and it says which half was missing"

echo "== 5. a recorded image this host does not hold is blindness, not agreement"
write_state
out=$(report IDS="kolonie-api=${GOOD} ${W_REF}=${GOOD} kolonie-website=${GOOD}" \
             MISSING="${A_REF} kolonie-verifier-runner kolonie-moderation-runner kolonie-support-triage-runner kolonie-badge-runner")
verdict=$(triage <<<"$out" 2>&1 >/dev/null)
sum=$(triage <<<"$out" 2>/dev/null)
contains "$verdict" "VERDICT=unknown" "verdict unknown"
contains "$sum" "not in this host's image store" "named as this check being blind"
absent "$sum" '| `api` | pinned |' "and emphatically not reported as pinned"

echo "== 6. drift outranks unknown when both are present"
# A host that is behind and a check that is partly blind can be true at once.
# The report has to lead with the one somebody must act on.
out=$(printf 'api\tref\t%s\t%s\nwebsite\t-\t-\t%s\n' "$GOOD" "$OTHER" "$GOOD")
verdict=$(triage <<<"$out" 2>&1 >/dev/null)
contains "$verdict" "VERDICT=drifted" "drifted wins"

echo "== 7. the fingerprint is stable while the fault is, and moves when it changes"
one=$(printf 'api\tref\t%s\t%s\n' "$GOOD" "$OTHER")
two=$(printf 'api\tref\t%s\t%s\nwebsite\tref\t%s\t%s\n' "$GOOD" "$OTHER" "$GOOD" "$OTHER")
fp1=$(triage <<<"$one" 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
fp2=$(triage <<<"$one" 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
fp3=$(triage <<<"$two" 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
check "same fault, same fingerprint" "$fp1" "$fp2"
check "a second service drifted changes it" "$([ "$fp1" != "$fp3" ] && echo differs || echo same)" "differs"

echo "== 8. a healthy row does not enter the fingerprint"
# Otherwise an unrelated redeploy re-files "what is wrong has changed" every
# quarter of an hour, and the comment that matters is buried under the ones that
# do not.
mixed=$(printf 'api\tref\t%s\t%s\nwebsite\tref\t%s\t%s\n' "$GOOD" "$OTHER" "$GOOD" "$GOOD")
fp4=$(triage <<<"$mixed" 2>&1 >/dev/null | sed -n 's/FINGERPRINT=//p')
check "the drifted service alone decides it" "$fp4" "$fp1"

echo "== 9. an empty probe is a broken watcher, not a clean host"
out=$(printf '' | triage 2>"$WORK/v"); status=$?
check "exit 2 — distinct from both ok and drifted" "$status" "2"
contains "$(cat "$WORK/v")" "VERDICT=unknown" "and it does not claim ok"
# On stderr, with the verdict, rather than on stdout: stdout is the report that
# gets pasted into an issue, and there is no report to make here.
contains "$(cat "$WORK/v")" "broken probe" "said the probe was empty"
check "and printed no report at all" "$out" ""

echo "== 10. it never deploys anything"
# Detecting drift and correcting it are different decisions (AGENTS.md §8).
out=$(triage <<<"$one" 2>/dev/null)
contains "$out" "This reports; it does not deploy" "said so in the report a person reads"
contains "$out" "rollback.sh" "and named the correction rather than performing it"

echo "== 11. the compose fallbacks cannot start an unpinned application container"
# The other half of #89, and the half no stub can reach: it is a property of
# docker-compose.yml rather than of a script. Asserted by reading the file.
compose="$ROOT/docker-compose.yml"
for var in API_IMAGE RUNNER_IMAGE MODERATION_IMAGE TRIAGE_IMAGE BADGE_IMAGE WEBSITE_IMAGE; do
  line=$(grep -F "\${${var}:-" "$compose")
  case "$line" in
    *":latest}"*) echo "  FAIL ${var} still falls back to :latest"; fail=$((fail+1)) ;;
    *"PIN-NOT-SET"*) echo "  ok   ${var} falls back to a tag that cannot exist"; pass=$((pass+1)) ;;
    *) echo "  FAIL ${var}: unrecognised fallback [$line]"; fail=$((fail+1)) ;;
  esac
done

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
