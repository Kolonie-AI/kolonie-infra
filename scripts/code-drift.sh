#!/bin/bash
# Kolonie AI — variables the code reads that compose never passes (#90)
#
# `scripts/env-drift.sh` compares two of the three places a variable can live:
# what `docker-compose.yml` reads, and what `.env.example` documents. **The
# missing leg is the code**, and it is the one that has shipped a defect twice.
#
# ## Why the third leg is the one that matters
#
# `apps/api` reads its configuration from `process.env`. A value in the host's
# `.env` reaches a container **only if `docker-compose.yml` names it** — the api
# service has no `env_file` — so a variable the code reads and compose does not
# list is permanently empty in production. Nothing fails, nothing logs, and the
# guard that depends on it simply always takes the unconfigured branch.
#
# `env-drift.sh` exits 0 on both known instances and is right to: neither
# variable is in `docker-compose.yml` at all, and a name compose never mentions
# cannot drift from a template.
#
# **`SMS_COLONY_NUMBER` (`kolonie-platform#480`).** The phone rung's guard read
# it; it was in neither `docker-compose.yml` nor `.env.example` nor the host's
# `.env`. So `sms-receive` refused every call from the day it shipped and no
# citizen could ever have passed it. A citizen found it by trying and filed a
# support ticket — the Colony learned about it from outside.
#
# **`MASTODON_VERIFIER_INSTANCES` (`kolonie-platform#482`).** The Mastodon
# allow-list, read by `apps/verifier-runner`, absent from `docker-compose.yml`.
# Setting it on the host would have done nothing.
#
# ## Two things that decide whether this is worth anything
#
# **0. It matches `env[...]`, not only `process.env[...]`.** The environment is
# routinely passed as a parameter and read through the alias:
#
#     export function mailerFromEnv(env: NodeJS.ProcessEnv = process.env) {
#       const senderName = env[MAIL_SENDER_NAME_VAR]
#
# Measured 2026-08-07: **more names are read that way than directly**, so a
# `process.env`-only version of this check was blind to most of the surface while
# reporting a clean result — the precise failure mode this file warns about one
# paragraph down. It was caught by `MAIL_SENDER_NAME` (kolonie-platform#483)
# being wired nowhere and this check saying nothing.
#
# **1. It resolves indirection, or it is blind to the class that bit.** Both real
# defects are read through a constant, not a literal:
#
#     export const MASTODON_INSTANCES_VAR = 'MASTODON_VERIFIER_INSTANCES'
#     process.env[MASTODON_INSTANCES_VAR]
#
# A grep for `process.env['…']` finds neither. **A version of this check that
# only matched string literals would report zero problems and be worse than
# nothing**, because it would look like coverage.
#
# **2. It excludes test files by path, not by matching text.** Writing the
# measurement by hand produced exactly one false positive —
# `MCP_SURFACE_REPORT`, which lives only in `mcp/surface-size.test.ts` — because
# the filter ran against `grep -o` output that carries no filename. A check that
# reports a test's variable as a production gap teaches its reader to skim it.
#
# ## Absent-with-a-default is reported and does not fail
#
# Measured 2026-08-07 against `kolonie-platform@88f342f` and
# `kolonie-infra@704bab6`: 45 names read by non-test code under `apps/*/src`, of
# which 6 are absent from `docker-compose.yml` — and **five of those six are
# deliberate in-code defaults**. Failing on all six would be a check that is
# wrong five times out of six, which is a check people switch off.
#
# So a read carrying `??` or `||` on the same statement is *safe* and is listed
# without failing the run; a read with no fallback is *load-bearing and inert*
# and fails it. That is `env-drift.sh`'s own rule — severity matches consequence
# — applied to the third leg.
#
# ## Why it runs here and not in kolonie-platform
#
# The comparison spans two repositories: the code is `kolonie-platform`, the
# compose file is here. It runs beside `env-drift.sh` and takes a path to a
# platform checkout, the same way that script already takes a path to a
# deployment directory — a third leg of an existing check rather than a new
# instrument. Both repositories are public, so the other tree is a clone rather
# than a credential.
#
# **Do not solve this by giving the api an `env_file`.** That would pass the
# host's whole `.env` into the container and make every secret visible to every
# process in it, which is a larger change than this defect justifies and is a
# security decision rather than a wiring one.
#
# Usage:
#   ./scripts/code-drift.sh /path/to/kolonie-platform
#
# Exit status:
#   0  nothing the code reads is missing from compose without a default
#   1  a load-bearing variable is inert, or the checkout could not be read
#
# **It never prints a value.** Variable *names* are the deliverable. This runs in
# workflows whose logs are public, and `env-drift.sh`'s rule holds here for the
# same reason: adding a value to the output publishes a production secret to a
# place that cannot be unpublished.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE:-$ROOT/docker-compose.yml}"
PLATFORM="${1:-}"

if [ -z "$PLATFORM" ]; then
    echo "FAIL: give me a path to a kolonie-platform checkout"
    echo "Usage: $0 /path/to/kolonie-platform"
    exit 1
fi

if [ ! -d "$PLATFORM/apps" ]; then
    echo "FAIL: $PLATFORM does not look like a kolonie-platform checkout (no apps/)"
    exit 1
fi

if [ ! -f "$COMPOSE" ]; then
    echo "FAIL: $COMPOSE not found — run this from a kolonie-infra checkout"
    exit 1
fi

# ---------------------------------------------------------------------------
# The sources the deployed code is built from.
#
# **`apps/*/src` and nothing else**, which is what the measurement in #90 was
# taken over — a name read only by `packages/` is reached through an app that
# reads it too, or it is not deployed configuration.
#
# **Test files are excluded by path**, never by matching their text. `-name
# '*.test.ts'` and the fixture directories, applied by `find` where the filename
# is still in hand — the false positive that motivates this ran a filter over
# `grep -o` output, which carries no filename at all.
# ---------------------------------------------------------------------------
sources() {
    find "$PLATFORM/apps" -type f -name '*.ts' \
        -path '*/src/*' \
        ! -name '*.test.ts' \
        ! -path '*/node_modules/*' \
        ! -path '*/dist/*' \
        ! -path '*/__fixtures__/*' \
        ! -path '*/__tests__/*' 2>/dev/null | sort || true
}

# Where a constant may be *defined*: anywhere in the platform's own source,
# because `MASTODON_INSTANCES_VAR` is declared in `packages/verifiers` and read
# in `apps/verifier-runner`. Tests are excluded here too — a constant defined
# only in a test is not deployed configuration.
definitions() {
    # **Roots that exist, and `|| true`.** `find` on a missing directory exits
    # non-zero, and under `set -e` that ends the script *before its first line of
    # output* — which is what a checkout with no `packages/` produced: exit 1,
    # nothing printed, indistinguishable from a finding. Measured 2026-08-07
    # against a fixture tree, which is the only place it could have been.
    local roots=("$PLATFORM/apps")
    [ -d "$PLATFORM/packages" ] && roots+=("$PLATFORM/packages")

    find "${roots[@]}" -type f -name '*.ts' \
        -path '*/src/*' \
        ! -name '*.test.ts' \
        ! -path '*/node_modules/*' \
        ! -path '*/dist/*' \
        ! -path '*/__fixtures__/*' \
        ! -path '*/__tests__/*' 2>/dev/null | sort || true
}

SOURCE_FILES="$(sources)"
DEFINITION_FILES="$(definitions)"

if [ -z "$SOURCE_FILES" ]; then
    echo "FAIL: no non-test sources found under $PLATFORM/apps/*/src"
    exit 1
fi

# ---------------------------------------------------------------------------
# Every name the code reads, by all three shapes.
# ---------------------------------------------------------------------------

# `grep` over the file list, tolerating *no match*.
#
# `xargs grep` exits 123 when a batch matches nothing, which under `set -e` and
# `pipefail` kills the script rather than yielding an empty list — and an empty
# list is the ordinary answer for two of the three shapes below.
scan() {
    printf '%s\n' "$SOURCE_FILES" | xargs grep -hoE "$1" 2>/dev/null || true
}

# process.env['LITERAL'] and process.env["LITERAL"]
literal_reads() {
    scan "(process\.)?\benv\[[\"'][A-Za-z_][A-Za-z0-9_]*[\"']\]" |
        sed -E "s/.*env\[[\"']//; s/[\"']\]//" | sort -u
}

# process.env.NAME
dotted_reads() {
    scan 'process\.env\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/process\.env\.//' | sort -u
}

# process.env[SOME_CONST] — the identifiers, before resolution.
constant_reads() {
    scan '(process\.)?\benv\[[A-Za-z_][A-Za-z0-9_]*\]' | sed -E 's/.*env\[//; s/\]//' | sort -u
}

# What one identifier holds. **A declaration, and only in SCREAMING_SNAKE_CASE.**
#
# Both halves are load-bearing and the first version of this had neither.
# Without the declaration keyword it matched any assignment of a string to that
# name anywhere in the tree; without the case rule it tried to resolve
# `process.env[name]` — where `name` is a *function parameter* — and came back
# with whatever unrelated `name = '...'` the file listing reached first.
# Measured 2026-08-07: that produced `viewport` and `ProviderUnreachable` as
# reported variable names, neither of which is a variable.
#
# A lowercase identifier is a runtime value rather than a constant, and is
# reported below as something this check cannot see rather than resolved wrongly.
resolve_constant() {
    local identifier="$1"
    is_constant_shaped "$identifier" || return 0

    printf '%s\n' "$DEFINITION_FILES" |
        xargs grep -hoE "(const|let|var)[[:space:]]+${identifier}[[:space:]]*(:[^=]*)?=[[:space:]]*[\"'][A-Za-z_][A-Za-z0-9_]*[\"']" 2>/dev/null |
        sed -E "s/.*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']/\1/" | head -1 || true
}

# Whether an identifier is even the shape of an env-name constant. A lowercase
# one is a parameter or a local, and there is no name to compare against compose.
is_constant_shaped() {
    [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# ---------------------------------------------------------------------------
# Names deliberately absent from compose whose default this check cannot see.
#
# **The residue, and it is meant to stay short.** The `??`-on-the-line rule below
# catches a default written beside the read. It cannot catch one applied by the
# *callee* — `openRouterDirectionClassifier(key, process.env[DIRECTION_MODEL_VAR])`
# defaults inside the function, and no amount of grepping the call site sees that.
#
# `#90` allows exactly this: *"the five deliberate ones are recorded somewhere it
# reads."* A name here is listed as deliberate and does not fail the run; the
# file is the record and each line carries why.
# ---------------------------------------------------------------------------
ALLOW_FILE="${ALLOW_FILE:-$ROOT/scripts/code-drift.allow}"

allowed() {
    [ -f "$ALLOW_FILE" ] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$ALLOW_FILE" | awk '{print $1}' | grep -qxF "$1"
}

READ_NAMES="$(mktemp)"
UNRESOLVED="$(mktemp)"
DYNAMIC="$(mktemp)"
trap 'rm -f "$READ_NAMES" "$UNRESOLVED" "$DYNAMIC" 2>/dev/null || true' EXIT

{
    literal_reads
    dotted_reads
} >> "$READ_NAMES"

while IFS= read -r identifier; do
    [ -n "$identifier" ] || continue

    if ! is_constant_shaped "$identifier"; then
        # `process.env[name]`, where `name` is a parameter. There is no name to
        # compare, and saying so is the honest answer — resolving it anyway is
        # what invented two variables on 2026-08-07.
        printf '%s\n' "$identifier" >> "$DYNAMIC"
        continue
    fi

    resolved="$(resolve_constant "$identifier")"
    if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved" >> "$READ_NAMES"
    else
        # **Reported, never silently dropped.** An identifier this cannot
        # resolve is a hole in the check, and a hole that prints nothing is the
        # literal-only version of this script wearing a disguise.
        printf '%s\n' "$identifier" >> "$UNRESOLVED"
    fi
done < <(constant_reads)

sort -u -o "$DYNAMIC" "$DYNAMIC"

sort -u -o "$READ_NAMES" "$READ_NAMES"
sort -u -o "$UNRESOLVED" "$UNRESOLVED"

# ---------------------------------------------------------------------------
# What compose passes **into a container**.
#
# **The keys of the `environment:` mappings, not the `${VAR}` names inside
# them**, and that distinction is the whole correctness of this check. The two
# are routinely different:
#
#     OPENROUTER_API_KEY: ${OPENROUTER_API_KEY_MODERATION:-}
#
# The container receives `OPENROUTER_API_KEY`; the host supplies
# `OPENROUTER_API_KEY_MODERATION`. `env-drift.sh` reads the right-hand side
# because its question is *what does compose want from the host*. This script's
# question is *what does the process actually see*, and that is the left.
#
# Reading the right-hand side instead reported four names as inert that compose
# passes perfectly well — measured 2026-08-07, and it would have made the first
# genuine finding indistinguishable from four false ones.
# ---------------------------------------------------------------------------
passed_by_compose() {
    # Keys under an `environment:` block: six-space-indented `NAME:` lines. Both
    # forms are matched — `NAME: value` and the `- NAME=value` list shape.
    # `|| true` on both: a compose file using only one of the two shapes is
    # ordinary, and `pipefail` turns "the other shape matched nothing" into a
    # script that exits before printing anything.
    {
        { grep -oE '^[[:space:]]{4,}[A-Z_][A-Z0-9_]*:' "$COMPOSE" || true; } | tr -d ' :'
        { grep -oE '^[[:space:]]*-[[:space:]]*[A-Z_][A-Z0-9_]*=' "$COMPOSE" || true; } | sed 's/[- =]//g'
    } | sort -u
}

PASSED="$(passed_by_compose)"

# ---------------------------------------------------------------------------
# Whether a read carries its own fallback.
#
# `??` or `||` on the same line as the read. Line-scoped rather than
# statement-scoped, which is the honest limitation: a fallback wrapped onto the
# next line by the formatter reads as absent, and the answer to that is a
# reported name somebody looks at once — not a parser.
# ---------------------------------------------------------------------------
# **A fallback to the empty string is not a default.**
#
# `process.env['SMS_COLONY_NUMBER'] ?? ''` is what `kolonie-platform#480` looked
# like: the `??` is there, and what it falls back to is *unconfigured*. The guard
# then refused every call from the day it shipped. Counting that as a default is
# how this check would have reported the regression case as safe — which it did,
# on the first run against `96cd078` on 2026-08-07, before this rule existed.
#
# So the fallback has to be a *value*: a number, a constant, an expression. An
# empty string literal is the unconfigured branch wearing a default's clothes.
has_default() {
    local name="$1"
    printf '%s\n' "$SOURCE_FILES" |
        { xargs grep -hE "env(\[[\"']?${name}[\"']?\]|\.${name}\b)" 2>/dev/null || true; } |
        grep -E '\?\?|\|\|' |
        grep -qvE "(\?\?|\|\|)[[:space:]]*(''|\"\")"
}

# A name read through a constant: the fallback sits beside `process.env[CONST]`,
# so look for the identifier that resolves to this name too.
has_default_via_constant() {
    local name="$1"
    while IFS= read -r identifier; do
        [ -n "$identifier" ] || continue
        [ "$(resolve_constant "$identifier")" = "$name" ] || continue
        if printf '%s\n' "$SOURCE_FILES" |
            { xargs grep -hE "env\[${identifier}\]" 2>/dev/null || true; } |
            grep -E '\?\?|\|\|' |
            grep -qvE "(\?\?|\|\|)[[:space:]]*(''|\"\")"; then
            return 0
        fi
    done < <(constant_reads)
    return 1
}

echo "=== code drift ==="
echo "platform checkout: $PLATFORM"
echo "compose file:      $COMPOSE"
echo "names read by non-test code under apps/*/src: $(wc -l < "$READ_NAMES")"
echo "names passed by docker-compose.yml:           $(printf '%s\n' "$PASSED" | wc -l)"
echo

INERT=""
DEFAULTED=""

while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$PASSED" | grep -qxF "$name" && continue

    if allowed "$name" || has_default "$name" || has_default_via_constant "$name"; then
        DEFAULTED="${DEFAULTED}${name}"$'\n'
    else
        INERT="${INERT}${name}"$'\n'
    fi
done < "$READ_NAMES"

report() {
    local heading="$1" body="$2"
    echo "$heading"
    if [ -z "${body//[$'\n' ]/}" ]; then
        echo "  (none)"
    else
        printf '%s' "$body" | sed '/^$/d; s/^/  /'
    fi
    echo
}

FAILED=0

report "read by the deployed code, never passed by compose, and carrying NO in-code default — set on the host it would still be empty:" "$INERT"
[ -n "${INERT//[$'\n' ]/}" ] && FAILED=1

report "absent from compose but carrying an in-code default — deliberate, and listed so a reader can tell the two apart:" "$DEFAULTED"

if [ -s "$DYNAMIC" ]; then
    report "read through a runtime value rather than a name — this check cannot say what those are, and there is nothing to compare:" "$(cat "$DYNAMIC")"
fi

if [ -s "$UNRESOLVED" ]; then
    report "read through an identifier this check could not resolve — a hole in the check itself, not a finding about the code:" "$(cat "$UNRESOLVED")"
    FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK — every variable the code reads is passed by compose or has its own default"
else
    echo "DRIFT — a variable the code reads is permanently empty in production"
fi

exit "$FAILED"
