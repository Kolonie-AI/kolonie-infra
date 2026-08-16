#!/bin/bash
# Rehearse image-prune.sh without Docker, a host, or an image store (#91).
#
# Usage: ./scripts/rehearse-image-prune.sh
#
# `image-prune.sh` deletes things on the deploy host, so the property worth
# testing is not that it removes old builds — that is the easy half and it is
# visible in one run. It is that it *never* removes the four kinds of image the
# host cannot recover cheaply: the rollback target named in `state/deployed.env`,
# the cascade marker in `state/needs-redeploy.env`, anything a container holds,
# and the newest builds kept as a margin.
#
# Those are exactly the cases a live trial does not exercise, because on a
# healthy host the rollback target is also the running image and every rule
# protects it at once. So the fixtures below pull them apart deliberately: the
# recorded digest is made *old*, older than the margin and referenced by no
# container, which is the state a host reaches the day after a single-service
# deploy carried its line over.
#
# The stub answers as the daemon does and records what it was asked to remove.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
BIN="$WORK/.bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$BIN" "$WORK/state"

GH=ghcr.io/kolonie-ai

# --- the fixture ----------------------------------------------------------
# One line per image: repository, tag, short id, creation time, manifest digest.
# Creation time is what the script sorts on, and the tags are commit-SHA-shaped
# precisely because they do *not* sort into build order — a script that sorted
# by tag would pass every other test here and keep the wrong five.
#
# **The id and the digest are different values, and that is not fixture
# decoration.** `state/deployed.env` names a manifest digest; `docker images`
# reports a config id; they never match, and `docker inspect` is what maps one
# to the other. A stub that used one string for both would let a script pass
# that compared the recorded digest against the image list directly, which is
# the shape of the mistake that deletes a rollback target.
id() { printf '%s%011d' "$1" "$2"; }
dg() { printf '%s%063d' "$1" "$2"; }

row() { # repo tag id createdAt digest
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

{
  # kolonie-api: eight builds, newest first by date.
  row "$GH/kolonie-api" f0000001 "$(id a 1)" "2026-08-07 09:44:52 +0000 UTC" "$(dg a 1)"
  row "$GH/kolonie-api" f0000002 "$(id a 2)" "2026-08-07 08:10:00 +0000 UTC" "$(dg a 2)"
  row "$GH/kolonie-api" f0000003 "$(id a 3)" "2026-08-07 07:00:00 +0000 UTC" "$(dg a 3)"
  row "$GH/kolonie-api" f0000004 "$(id a 4)" "2026-08-06 22:00:00 +0000 UTC" "$(dg a 4)"
  row "$GH/kolonie-api" f0000005 "$(id a 5)" "2026-08-06 12:00:00 +0000 UTC" "$(dg a 5)"
  row "$GH/kolonie-api" f0000006 "$(id a 6)" "2026-08-05 12:00:00 +0000 UTC" "$(dg a 6)"
  row "$GH/kolonie-api" f0000007 "$(id a 7)" "2026-08-04 12:00:00 +0000 UTC" "$(dg a 7)"
  # The recorded rollback target. Deliberately the oldest api build there is,
  # outside any plausible margin, and held by no container.
  row "$GH/kolonie-api" f0000008 "$(id a 8)" "2026-07-01 12:00:00 +0000 UTC" "$(dg a 8)"
  # kolonie-website: two builds, both inside the margin.
  row "$GH/kolonie-website" f0000009 "$(id b 1)" "2026-08-07 09:00:00 +0000 UTC" "$(dg b 1)"
  row "$GH/kolonie-website" f0000010 "$(id b 2)" "2026-08-01 09:00:00 +0000 UTC" "$(dg b 2)"
  # Third-party images. Not this script's business at any margin.
  row postgres 16-alpine "$(id c 1)" "2026-06-01 09:00:00 +0000 UTC" "$(dg c 1)"
  row traefik  v3.7      "$(id d 1)" "2026-06-01 09:00:00 +0000 UTC" "$(dg d 1)"
  # kolonie-moderation-runner: an old build held by a *stopped* container, and a
  # new one held by nothing. The old one is in no other protected set.
  row "$GH/kolonie-moderation-runner" f0000011 "$(id e 1)" "2026-07-02 12:00:00 +0000 UTC" "$(dg e 1)"
  row "$GH/kolonie-moderation-runner" f0000012 "$(id e 2)" "2026-08-07 09:00:00 +0000 UTC" "$(dg e 2)"
  # kolonie-badge-runner: the build both halves of a half-finished recreate hold
  # — the live container and the leftover beside it (#188).
  row "$GH/kolonie-badge-runner" f0000013 "$(id g 1)" "2026-08-07 09:00:00 +0000 UTC" "$(dg g 1)"
} > "$WORK/images"

# One line per container: id, the image it holds, its name, its state, and the
# compose project it belongs to. The last three exist for #188: the sweep reads
# all three and a container that fails any one of them is somebody's to keep.
{
  printf 'c1\tsha256:%s\tkolonie-api\trunning\tkolonie\n'                "$(id a 1)"
  printf 'c2\tsha256:%s\tkolonie-website\trunning\tkolonie\n'            "$(id b 1)"
  # An ordinary stopped container. Nothing about it is recreate-shaped, and a
  # sweep that reached it would be removing something somebody may start.
  printf 'c3\tsha256:%s\tkolonie-moderation-runner\texited\tkolonie\n'   "$(id e 1)"
  # The leftover, in the shape #96 and #183 arrived in, beside the live one it
  # was renamed out of the way for.
  printf 'c4\tsha256:%s\tf16be25a578c_kolonie-badge-runner\texited\tkolonie\n' "$(id g 1)"
  printf 'c5\tsha256:%s\tkolonie-badge-runner\trunning\tkolonie\n'       "$(id g 1)"
  # Recreate-shaped, this project's name in it — and another project's label.
  # A name is not ownership, which is why the label is one of the three.
  printf 'c6\tsha256:%s\t0123456789ab_kolonie-verifier-runner\texited\tsomebody-else\n' "$(id a 2)"
  # Recreate-shaped and *running*. Compose renames before it recreates, so this
  # is what the leftover looks like for the seconds before the deploy finishes.
  printf 'c7\tsha256:%s\tabcdef012345_kolonie-api\trunning\tkolonie\n'   "$(id a 1)"
} > "$WORK/containers"

printf '%s\n%s\n' "$(id f 1)" "$(id f 2)" > "$WORK/dangling"

# --- the stub -------------------------------------------------------------
cat > "$BIN/docker" <<'STUB'
#!/bin/bash
IMAGES="$STUB_IMAGES"; CONTAINERS="$STUB_CONTAINERS"; DANGLING="$STUB_DANGLING"
REMOVED="$STUB_REMOVED"

full() { printf 'sha256:%s\n' "$1"; }

case "$1" in
  info) exit "${STUB_INFO_FAILS:-0}" ;;

  ps)   # `ps -aq` for the protected set, and `ps -a --format` for #188's sweep.
        shift
        fmt=""
        while [ $# -gt 0 ]; do
          case "$1" in --format) fmt="$2"; shift ;; esac
          shift
        done
        if [ -z "$fmt" ]; then cut -f1 "$CONTAINERS"; exit 0; fi
        while IFS=$'\t' read -r cid img nm st proj; do
          out="$fmt"
          out=${out//'{{.Names}}'/$nm}
          out=${out//'{{.State}}'/$st}
          out=${out//'{{.Label "com.docker.compose.project"}}'/$proj}
          printf '%b\n' "$out"
        done < "$CONTAINERS" ;;

  rm)   # A container removal, which is a different verb from `image rm` and is
        # recorded under its own prefix so the two cannot be confused.
        printf 'RM %s\n' "$2" >> "$REMOVED"
        [ "$2" = "${STUB_RM_CONTAINER_REFUSES:-}" ] && exit 1
        exit 0 ;;

  inspect)
        # inspect --format <fmt> <ref>
        fmt="$3"; ref="$4"
        case "$fmt" in
          '{{.Image}}')
              # a container id -> the image it holds
              if [ "${STUB_CONTAINER_UNREADABLE:-}" = "$ref" ]; then exit 1; fi
              line=$(grep -P "^$ref\t" "$CONTAINERS") || exit 1
              printf '%s\n' "$(cut -f2 <<<"$line")" ;;
          '{{.Id}}')
              # a short id, a repo:tag, or a repo@sha256:… -> the full config id
              case "$ref" in
                *@sha256:*)
                    # Resolved through the digest column, as the daemon resolves
                    # it through RepoDigests. The answer is the config id, which
                    # is a different value from the digest asked for.
                    want=${ref##*@sha256:}
                    line=$(grep -P "\t\Q$want\E$" "$IMAGES") || exit 1
                    full "$(cut -f3 <<<"$line")" ;;
                *:*)
                    r=${ref%:*}; t=${ref##*:}
                    line=$(grep -P "^\Q$r\E\t\Q$t\E\t" "$IMAGES") || exit 1
                    full "$(cut -f3 <<<"$line")" ;;
                *)
                    grep -qP "\t${ref}\t" "$IMAGES" && full "$ref" || exit 1 ;;
              esac ;;
          *) echo "STUB: unexpected inspect format: $fmt" >&2; exit 125 ;;
        esac ;;

  images)
        shift
        repo=""; fmt=""; quiet=0; dangling=0
        while [ $# -gt 0 ]; do
          case "$1" in
            -q) quiet=1 ;;
            -f) [ "$2" = "dangling=true" ] && dangling=1; shift ;;
            --format) fmt="$2"; shift ;;
            -*) ;;
            *) repo="$1" ;;
          esac
          shift
        done
        if [ "$dangling" = 1 ]; then cat "$DANGLING"; exit 0; fi
        rows=$(cat "$IMAGES")
        [ -n "$repo" ] && rows=$(grep -P "^\Q$repo\E\t" "$IMAGES")
        [ -z "$rows" ] && exit 0
        if [ "$quiet" = 1 ]; then cut -f3 <<<"$rows"; exit 0; fi
        while IFS=$'\t' read -r r t i c d; do
          out="$fmt"
          out=${out//'{{.Repository}}'/$r}
          out=${out//'{{.Tag}}'/$t}
          out=${out//'{{.ID}}'/$i}
          out=${out//'{{.CreatedAt}}'/$c}
          printf '%b\n' "$out"
        done <<<"$rows" ;;

  image)
        case "$2" in
          rm)   printf '%s\n' "$3" >> "$REMOVED"
                # A removal the daemon refuses: the script must carry on and
                # report it rather than treat it as its own failure.
                [ "$3" = "${STUB_RM_REFUSES:-}" ] && exit 1
                exit 0 ;;
          prune) printf 'PRUNED-DANGLING\n' >> "$REMOVED"; exit 0 ;;
        esac ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

# The script reaches for `sudo docker` whenever it is not root, and CI is not
# root. Passing the stub through is the whole job of this one.
cat > "$BIN/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
chmod +x "$BIN/sudo"

cat > "$BIN/df" <<'STUB'
#!/bin/bash
if printf '%s\n' "$@" | grep -q -- '--output=pcent'; then
  printf 'Use%%\n15%%\n'
elif printf '%s\n' "$@" | grep -q -- '--output=used'; then
  if [ -s "$STUB_REMOVED" ]; then
    printf 'Used\n7000000000\n'
  else
    printf 'Used\n9000000000\n'
  fi
elif printf '%s\n' "$@" | grep -q -- '--output=size'; then
  printf 'Size\n96G\n'
else
  exit 1
fi
STUB
chmod +x "$BIN/df"

# --- the harness ----------------------------------------------------------
pass=0; fail=0
check()    { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$3], got [$2]"; fail=$((fail+1)); fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then echo "  ok   $3"; pass=$((pass+1)); else echo "  FAIL $3"; fail=$((fail+1)); fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then echo "  FAIL $3"; fail=$((fail+1)); else echo "  ok   $3"; pass=$((pass+1)); fi; }

prune() {
  : > "$WORK/removed"
  PATH="$BIN:$PATH" \
  STUB_IMAGES="$WORK/images" STUB_CONTAINERS="$WORK/containers" \
  STUB_DANGLING="$WORK/dangling" STUB_REMOVED="$WORK/removed" \
  DEPLOY_DIR="$WORK" IMAGE_PRUNE_STATE_DIR="${IMAGE_PRUNE_STATE_DIR:-$WORK/state}" \
  "$@" bash "$ROOT/scripts/image-prune.sh" ${PRUNE_ARGS:-}
}

removed() { cat "$WORK/removed"; }

cat > "$WORK/state/deployed.env" <<EOF
DEPLOYED_AT=20260807_094452
API_IMAGE=$GH/kolonie-api@sha256:$(dg a 8)
WEBSITE_IMAGE=$GH/kolonie-website@sha256:$(dg b 1)
# A digest this host never pulled — a single-service deploy carried the line
# over. It must be skipped in silence, not treated as an error.
RUNNER_IMAGE=$GH/kolonie-verifier-runner@sha256:$(dg 0 9)
EOF

echo "== 1. the recorded rollback target survives, though it is the oldest build there is"
out=$(KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
absent "$(removed)" "$GH/kolonie-api:f0000008" "the deployed.env digest was not removed"
contains "$out" "Protected by a state record:   2" "counted both digests it could resolve"
contains "$out" "Freed:  2000000000 bytes" "reported the bytes freed by the run"
contains "$(cat "$WORK/state/image-prune.env")" "LAST_FREED_BYTES=2000000000" "recorded the result for Health Watch"
# #119: the marker is written by root under systemd and read by the deploy user
# over SSH. A mode that only the writer can read makes a successful prune report
# `never`, which is the whole of that issue.
check "the marker is readable by its reader, not only its writer" \
    "$(stat -c '%a' "$WORK/state/image-prune.env")" "644"

echo "== 2. …and the builds beyond the margin do go"
contains "$(removed)" "$GH/kolonie-api:f0000004" "the fourth-newest api build was removed"
contains "$(removed)" "$GH/kolonie-api:f0000007" "and the seventh"

echo "== 3. the newest KEEP_BUILDS of each repository stay"
absent "$(removed)" "$GH/kolonie-api:f0000001" "newest api build kept"
absent "$(removed)" "$GH/kolonie-api:f0000002" "second kept"
absent "$(removed)" "$GH/kolonie-api:f0000003" "third kept"

echo "== 4. an image a stopped container holds is never removed"
# c3 holds an old moderation build that no other rule protects. A prune that
# takes it turns `docker start` into a pull, on the host that ran out of disk.
absent "$(removed)" "$GH/kolonie-moderation-runner:f0000011" "the stopped container's image survived"

echo "== 5. third-party images are not this script's business"
absent "$(removed)" "postgres:16-alpine" "postgres untouched"
absent "$(removed)" "traefik:v3.7" "traefik untouched"

echo "== 6. --dry-run reaches the decision and removes nothing"
out=$(PRUNE_ARGS=--dry-run KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
check "nothing removed" "$(wc -l < "$WORK/removed" | tr -d ' ')" "0"
contains "$out" "Mode: dry run" "said so"
contains "$out" "Old builds to remove:" "and still counted them"
contains "$out" "Freed:  0 bytes" "reported that the dry run freed nothing"

echo "== 7. the cascade marker is protected when it exists"
# #79: needs-redeploy.env holds the image reference of a build that was rolled
# back, and the escape from the cascade re-deploys exactly that one.
printf 'NEEDS_REDEPLOY_IMAGE=%s/kolonie-api@sha256:%s\n' "$GH" "$(dg a 6)" \
  > "$WORK/state/needs-redeploy.env"
KEEP_BUILDS=3 prune >/dev/null 2>&1
absent "$(removed)" "$GH/kolonie-api:f0000006" "the marked build survived"
rm -f "$WORK/state/needs-redeploy.env"

echo "== 8. a container whose image cannot be read stops the run before anything goes"
out=$(STUB_CONTAINER_UNREADABLE=c2 KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 1" "$status" "1"
check "nothing removed" "$(wc -l < "$WORK/removed" | tr -d ' ')" "0"
contains "$out" "refusing to prune" "said why it stopped"
contains "$out" "nothing has been removed" "and that it had changed nothing"

echo "== 9. a removal the daemon refuses is reported, not fatal"
# An image can gain a container between the scan and the removal. Leaving it
# and saying so is the answer; --force is not.
out=$(STUB_RM_REFUSES="$GH/kolonie-api:f0000004" KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "Refused by Docker, left alone: 1" "counted the refusal separately"

echo "== 10. a margin of zero is refused"
# KEEP_BUILDS=0 protects nothing but what is running and what is recorded, which
# is the arrangement #91 was filed about arriving at by accident.
out=$(KEEP_BUILDS=0 prune 2>&1); status=$?
check "exit 1" "$status" "1"
check "nothing removed" "$(wc -l < "$WORK/removed" | tr -d ' ')" "0"
contains "$out" "at least 1" "said what it wanted"

echo "== 11. a daemon it cannot reach is a refusal, not an empty prune"
out=$(STUB_INFO_FAILS=1 prune 2>&1); status=$?
check "exit 1" "$status" "1"
check "nothing removed" "$(wc -l < "$WORK/removed" | tr -d ' ')" "0"
contains "$out" "cannot reach the Docker daemon" "said so"

echo "== 12. dangling images are pruned, and only when not rehearsing"
KEEP_BUILDS=3 prune >/dev/null 2>&1
contains "$(removed)" "PRUNED-DANGLING" "dangling prune ran"
PRUNE_ARGS=--dry-run KEEP_BUILDS=3 prune >/dev/null 2>&1
absent "$(removed)" "PRUNED-DANGLING" "and not under --dry-run"

echo "== 13. a leftover from a failed recreate is swept, and nothing beside it (#188)"
# Three conditions, and each of c3, c6 and c7 fails exactly one of them. A sweep
# that tested two would take one of the three, which is why they are here.
out=$(COMPOSE_PROJECT=kolonie KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "Leftover containers:           1" "counted one"
contains "$(removed)" "RM f16be25a578c_kolonie-badge-runner" "the leftover was removed"
check "and it was the only container removed" "$(grep -c '^RM ' "$WORK/removed")" "1"
absent "$(removed)" "RM kolonie-moderation-runner" "an ordinary stopped container was not touched"
absent "$(removed)" "RM 0123456789ab_kolonie-verifier-runner" "nor one carrying another project's label"
absent "$(removed)" "RM abcdef012345_kolonie-api" "nor a recreate-shaped one that is still running"

echo "== 14. the sweep runs after the images, so this run cannot strip its own protection"
# The protected sets are computed at the top of the run. Removing the leftover
# last means the image it held keeps the protection it was granted minutes ago,
# and becomes a candidate no earlier than next week — with the margin still in
# front of it. A sweep placed before the scan would delete both in one pass.
absent "$(removed)" "$GH/kolonie-badge-runner:f0000013" "the leftover's image survived the run that removed the leftover"

echo "== 15. --dry-run names the leftover and removes nothing"
out=$(PRUNE_ARGS=--dry-run COMPOSE_PROJECT=kolonie KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "would remove f16be25a578c_kolonie-badge-runner" "said which"
contains "$out" "left behind by a recreate of kolonie-badge-runner" "and named the live one it belongs to"
check "nothing removed" "$(grep -c '^RM ' "$WORK/removed" || true)" "0"

echo "== 16. a compose project that is not this one sweeps nothing"
# Fail-safe by design: a host whose project is named something else removes no
# container at all rather than reaching for one it does not own, and the count
# says so rather than the run going quiet.
out=$(COMPOSE_PROJECT=kolonie-staging KEEP_BUILDS=3 prune 2>&1); status=$?
contains "$out" "Leftover containers:           0" "found none to sweep"
check "nothing removed" "$(grep -c '^RM ' "$WORK/removed" || true)" "0"

echo "== 17. a container removal the daemon refuses is reported, not fatal"
out=$(STUB_RM_CONTAINER_REFUSES=f16be25a578c_kolonie-badge-runner \
      COMPOSE_PROJECT=kolonie KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 0" "$status" "0"
contains "$out" "refused by Docker, left alone: f16be25a578c_kolonie-badge-runner" "named it and carried on"

echo "== 18. an unknown argument is refused rather than ignored"
out=$(PRUNE_ARGS=--force KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 1" "$status" "1"
contains "$out" "unknown argument" "named it"

echo "== 19. no writable status directory means no deletion"
out=$(IMAGE_PRUNE_STATE_DIR="$WORK/missing" KEEP_BUILDS=3 prune 2>&1); status=$?
check "exit 1" "$status" "1"
check "nothing removed" "$(wc -l < "$WORK/removed" | tr -d ' ')" "0"
contains "$out" "status directory is not writable" "refused before changing the image store"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
