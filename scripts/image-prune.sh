#!/bin/bash
# Kolonie AI — remove application images no longer worth keeping (#91)
#
# Every build of every service leaves a tagged image on this host and nothing
# has ever removed one. Measured on the deploy host on 2026-08-07, when the
# partition reached 85 % of 96 GB:
#
#   1509 images, 82.6 GB, of which 58.24 GB reclaimable
#   398 kolonie-api, 319 verifier-runner, 307 moderation-runner,
#   229 support-triage-runner, 130 badge-runner, 66 website
#
# Each is tagged with the full commit SHA it was built from, so they never
# collide and never replace one another. At ~373 MB per api build, the growth
# rate is the deploy rate — roughly 45 commits a day across the two application
# repositories — and the endpoint is a full partition.
#
# **A full partition is the failure this exists to prevent, and it is worse than
# the sum of its services.** Every container stops at once, and for a reason none
# of their logs can record, because there is nowhere left to record it. Container
# logs are capped in docker-compose.yml (#37); the image store never was.
#
# ## Why not `docker system prune -a`
#
# That removes every image no *container* references, and the rollback target is
# usually not referenced by a container. `state/deployed.env` names six digests
# and `rollback.sh` returns to those and to nothing else (#12) — but a
# single-service deploy rewrites only its own line and carries the other five
# over, so the file legitimately names builds that are not currently up. Pruning
# by container reference alone deletes exactly the image a rollback needs, and it
# does so on the day before it is needed rather than on the day it is noticed.
#
# So the protected set is computed here rather than inferred from what is
# running.
#
# ## What is protected, and it is three sets and not one
#
#   1. Every image an existing container references — running or stopped.
#   2. Every digest named in state/deployed.env, and in
#      state/needs-redeploy.env when the cascade marker exists (#79). These are
#      the recovery inputs and they are protected by name, not by luck.
#   3. The KEEP_BUILDS most recent builds of each application repository, as a
#      margin for a rollback to a build older than the last recorded one.
#
# ## Why third-party images are never touched
#
# `postgres:16-alpine`, `traefik:v3.7` and the rest are pinned by tag rather than
# by digest, so deleting one and pulling it back is not guaranteed to return the
# same bytes. They are also a rounding error — eleven images against fifteen
# hundred. This script matches `ghcr.io/kolonie-ai/` and nothing else, and the
# one exception is dangling images, which belong to no repository by definition.
#
# ## Why a five-build margin is a margin and not a guess
#
# The application images are public on GHCR since #58, so a deleted build is
# re-pullable by digest for as long as the registry keeps it. That is what makes
# deleting hundreds of them defensible rather than reckless. It is *not* what
# makes the margin unnecessary: re-pulling needs the network, GHCR, and someone
# who knows which digest to ask for, and a rollback happens on the day none of
# that is going well. Set 1 and set 2 are therefore protected outright, and the
# margin is for the case nobody wrote down.
#
# Usage, on the deploy host:
#   ./scripts/image-prune.sh                 remove what is not protected
#   ./scripts/image-prune.sh --dry-run       say what it would remove, change nothing
#
# Environment:
#   KEEP_BUILDS   builds kept per application repository (default 5)
#   DEPLOY_DIR    where state/deployed.env lives (default /opt/kolonie)
#
# Exit status:
#   0  the prune ran, whether or not it had anything to remove
#   1  the host could not be read well enough to prune safely
#
# **It never removes an image it could not prove unprotected.** A `docker
# inspect` that fails is a reason to keep, and the run says so — the alternative
# is a script whose safety depends on every command succeeding, on a host whose
# disk is by then nearly full.

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/kolonie}"
KEEP_BUILDS="${KEEP_BUILDS:-5}"
REGISTRY_PREFIX="ghcr.io/kolonie-ai/"

DRY_RUN=no
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=yes
elif [[ -n "${1:-}" ]]; then
    echo "FAIL: unknown argument '$1'. Usage: $0 [--dry-run]"
    exit 1
fi

# `sudo` when this is not already root: the timer runs it as root and a human
# runs it as `ubuntu`, and the docker socket is not readable by the latter.
DOCKER=(docker)
if [[ "$(id -u)" != "0" ]]; then
    DOCKER=(sudo docker)
fi

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
    echo "FAIL: cannot reach the Docker daemon — nothing has been changed"
    exit 1
fi

case "$KEEP_BUILDS" in
    ''|*[!0-9]*) echo "FAIL: KEEP_BUILDS must be a number, got '$KEEP_BUILDS'"; exit 1 ;;
esac
if [[ "$KEEP_BUILDS" -lt 1 ]]; then
    echo "FAIL: KEEP_BUILDS must be at least 1 — a margin of zero is what #91 is about"
    exit 1
fi

echo "=== Image prune ==="
echo "Deploy directory: $DEPLOY_DIR"
echo "Builds kept per repository: $KEEP_BUILDS"
[[ "$DRY_RUN" == yes ]] && echo "Mode: dry run — nothing will be removed"
echo

before_used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
before_images=$("${DOCKER[@]}" images -q | sort -u | wc -l)

# ---------------------------------------------------------------------------
# Set 1 — every image an existing container references.
#
# `docker ps -aq`, not `ps -q`: a stopped container is still a thing somebody
# may start, and its image disappearing turns a restart into a pull.
# ---------------------------------------------------------------------------
# Both scratch files are created before the trap is armed. An EXIT trap that
# expands a variable not yet assigned aborts under `set -u` *inside the trap*,
# which replaces whatever went wrong with a complaint about the trap — measured
# on the deploy host on 2026-08-07, where it hid the real fault completely.
protected=$(mktemp)
candidates=$(mktemp)
trap 'rm -f "$protected" "$candidates" 2>/dev/null || true' EXIT

# **An unexplained exit must not look like a finished prune.** Under `set -e` a
# failing command ends the script silently, and the last line printed then reads
# as the last thing that succeeded. On a script whose next section deletes
# images, that is the difference between "it stopped before removing anything"
# and "it stopped somewhere in the middle" — and on 2026-08-07 the first run on
# the deploy host could not be told apart, because the EXIT trap's own `set -u`
# failure was the only message that survived.
trap 'status=$?; echo "FAIL: aborted at line $LINENO with status $status"; \
      echo "FAIL: anything already removed is named above; nothing further was touched"' ERR

container_count=0
while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    container_count=$((container_count + 1))
    if ! "${DOCKER[@]}" inspect --format '{{.Image}}' "$cid" >> "$protected" 2>/dev/null; then
        echo "FAIL: could not read the image of container $cid — refusing to prune"
        echo "FAIL: nothing has been removed"
        exit 1
    fi
done < <("${DOCKER[@]}" ps -aq)

echo "Protected by a container:      $container_count"

# ---------------------------------------------------------------------------
# Set 2 — the recovery inputs, by name.
#
# A digest named in one of these files and absent from this host is not an
# error: a single-service deploy carries over lines for images that were never
# pulled here, and rollback.sh pulls what it needs. It is skipped silently.
# ---------------------------------------------------------------------------
recorded=0
for state_file in "$DEPLOY_DIR/state/deployed.env" "$DEPLOY_DIR/state/needs-redeploy.env"; do
    [[ -f "$state_file" ]] || continue
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        if id=$("${DOCKER[@]}" inspect --format '{{.Id}}' "$ref" 2>/dev/null); then
            echo "$id" >> "$protected"
            recorded=$((recorded + 1))
        fi
    done < <(grep -oE "${REGISTRY_PREFIX}[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}" "$state_file" || true)
done

echo "Protected by a state record:   $recorded"

# ---------------------------------------------------------------------------
# Set 3 — the newest KEEP_BUILDS of each application repository.
#
# Sorted by the daemon's CreatedAt rather than by the tag, because the tag is a
# commit SHA and a commit SHA does not sort into build order.
# ---------------------------------------------------------------------------
margin=0
repos=$("${DOCKER[@]}" images --format '{{.Repository}}' \
        | grep "^${REGISTRY_PREFIX}" | sort -u || true)

while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    kept=$("${DOCKER[@]}" images "$repo" --format '{{.CreatedAt}}\t{{.ID}}' \
           | sort -r | head -n "$KEEP_BUILDS" | cut -f2)
    while IFS= read -r short; do
        [[ -n "$short" ]] || continue
        if id=$("${DOCKER[@]}" inspect --format '{{.Id}}' "$short" 2>/dev/null); then
            echo "$id" >> "$protected"
            margin=$((margin + 1))
        fi
    done <<< "$kept"
done <<< "$repos"

echo "Protected as a rollback margin: $margin"

sort -u -o "$protected" "$protected"
echo "Distinct protected images:     $(wc -l < "$protected")"
echo

# ---------------------------------------------------------------------------
# The candidates: every tagged application image whose id is in none of the
# three sets. Removed by `repository:tag`, not by id — an id may carry several
# tags when two commits built identical trees, and removing one tag of such an
# image must untag it rather than fail.
# ---------------------------------------------------------------------------

while IFS=$'\t' read -r ref short; do
    [[ -n "$ref" ]] || continue
    case "$ref" in *:'<none>') continue ;; esac
    id=$("${DOCKER[@]}" inspect --format '{{.Id}}' "$short" 2>/dev/null) || continue
    grep -qxF "$id" "$protected" || printf '%s\n' "$ref" >> "$candidates"
done < <("${DOCKER[@]}" images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' \
         | grep "^${REGISTRY_PREFIX}" || true)

candidate_count=$(wc -l < "$candidates" | tr -d ' ')
echo "Old builds to remove:          $candidate_count"

removed=0
failed=0
if [[ "$DRY_RUN" == yes ]]; then
    head -20 "$candidates" || true
    [[ "$candidate_count" -gt 20 ]] && echo "  … and $((candidate_count - 20)) more"
else
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        # No `--force`. A removal docker refuses is a removal this script was
        # wrong about, and forcing it past that is how a prune becomes an
        # outage.
        if "${DOCKER[@]}" image rm "$ref" >/dev/null 2>&1; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$candidates"
    echo "Removed:                       $removed"
    # Not a failure. An image can gain a container reference between the scan
    # and the removal, and the right response is to leave it alone and say so.
    [[ "$failed" -gt 0 ]] && echo "Refused by Docker, left alone: $failed"
fi

# ---------------------------------------------------------------------------
# Dangling images — `<none>:<none>`, belonging to no repository at all. These
# are intermediate and superseded layers, and measured on the host on
# 2026-08-07 there were 96 of them.
#
# **An image pulled by digest is not dangling**, which is the thing to be sure
# of before running this near a rollback target: it keeps its repository and
# shows `<none>` only in the TAG column. Verified on the deploy host on
# 2026-08-07 against the api digest in deployed.env — absent from
# `images -f dangling=true`.
# ---------------------------------------------------------------------------
dangling=$("${DOCKER[@]}" images -f dangling=true -q | sort -u | wc -l)
echo "Dangling images:               $dangling"
if [[ "$DRY_RUN" == no && "$dangling" -gt 0 ]]; then
    "${DOCKER[@]}" image prune -f >/dev/null 2>&1 || true
fi

echo
after_used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
after_images=$("${DOCKER[@]}" images -q | sort -u | wc -l)
echo "Images: $before_images -> $after_images"
echo "Disk:   ${before_used}% -> ${after_used}% of $(df -h --output=size / | tail -1 | tr -d ' ')"

# A prune that removed nothing is a normal quiet run and exits 0, the same way
# helius-payment-webhook.sh treats a webhook that is already correct. What this script must
# never do is exit non-zero on a full disk and be silenced by whoever is tired
# of the alert.
exit 0
