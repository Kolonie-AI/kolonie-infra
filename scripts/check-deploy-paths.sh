#!/bin/bash
# Kolonie AI — does AGENTS.md still quote the deploy filter the workflow uses? (#170)
#
# Usage: ./scripts/check-deploy-paths.sh
#
# §8 tells an agent that merging to `main` deploys, and that the `paths-ignore`
# list in `deploy.yml` is the whole of the exemption. A reader who disagrees with
# that has to be able to check it, so §8 quotes the list rather than describing
# it — and a quoted list is a second copy of a fact, which is exactly what D-002
# says goes out of step while the one being read looks authoritative.
#
# So the copy is asserted against the original. Add a pattern to the workflow
# without touching §8 and this fails, naming both.
#
# It reads the block by its fence rather than by line number: the fence in §8 is
# ```yaml and carries the `paths-ignore:` key, and nothing else in the file does.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOC="$ROOT/AGENTS.md"
WORKFLOW="$ROOT/.github/workflows/deploy.yml"

[ -f "$DOC" ] || { echo "no AGENTS.md at $DOC" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "no deploy.yml at $WORKFLOW" >&2; exit 2; }

# The patterns as the workflow has them: from `paths-ignore:` to the first line
# that is not a list item, quotes stripped so the comparison is about the pattern
# and not about how YAML happened to spell it.
patterns_from() {
    awk '
        /^[[:space:]]*paths-ignore:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]*-[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/^['"'"'"]|['"'"'"]$/, "", line)
            print line
            next
        }
        inside { exit }
    ' "$1"
}

# The same, out of the fenced block in §8. `sed` narrows to the fence first so a
# `paths-ignore:` in prose elsewhere cannot be mistaken for the quote.
doc_block=$(sed -n '/^```yaml$/,/^```$/p' "$DOC" | grep -A 100 'paths-ignore:')

actual=$(patterns_from "$WORKFLOW")
quoted=$(printf '%s\n' "$doc_block" | patterns_from /dev/stdin)

if [ -z "$actual" ]; then
    echo "deploy.yml has no paths-ignore list, or it is written in a shape this check cannot read." >&2
    exit 1
fi

if [ -z "$quoted" ]; then
    echo "AGENTS.md §8 no longer quotes the paths-ignore list." >&2
    echo "That section tells an agent which changes reach the host; without the list it is a paraphrase." >&2
    exit 1
fi

if [ "$actual" != "$quoted" ]; then
    echo "AGENTS.md §8 quotes a paths-ignore list that .github/workflows/deploy.yml does not have:" >&2
    diff <(printf '%s\n' "$quoted") <(printf '%s\n' "$actual") \
        --label 'AGENTS.md §8' --label '.github/workflows/deploy.yml' -u >&2
    echo "The workflow decides what deploys. Update the quote." >&2
    exit 1
fi

count=$(printf '%s\n' "$actual" | wc -l | tr -d ' ')
echo "AGENTS.md §8 quotes the deploy filter the workflow uses ($count patterns)."
