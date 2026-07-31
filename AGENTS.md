# AGENTS.md — kolonie-infra

This file is binding for any agent working in this repository. Read it fully
before your first edit. If it contradicts your general habits, this file wins.

---

## 1. What this repository is

The infrastructure that keeps the Colony running: Docker Compose configurations,
Traefik reverse proxy, deployment scripts, GitHub Actions pipelines, and the
operational tooling that monitors and diagnoses the host.

```
docker-compose.yml          production compose — five services, two profiles
docker-compose.dev.yml      local development override (Postgres only)
traefik/                    static and dynamic Traefik v3 configuration
scripts/deploy.sh           the deploy — pull, pin, migrate, seed, deploy, healthcheck
scripts/rehearse-deploy.sh  exercises deploy.sh against a stub docker
scripts/healthcheck.sh      post-deploy health assertion
scripts/rollback.sh         manual rollback to the last known-good build
scripts/backup.sh           daily pg_dump into an off-host restic repository (#4)
scripts/rehearse-backup.sh  exercises backup.sh against a stub docker and restic
scripts/env-drift.sh        detects .env vs docker-compose.yml mismatches
scripts/deployed-revision.sh  which commit each running container was built from
scripts/drift-triage.sh     decides whether the host is behind what was last built
scripts/rehearse-drift.sh   exercises drift-triage.sh against a stub gh
scripts/health-report.sh    structured health report for the diagnose workflow
scripts/health-why.sh       why an unhealthy container says so — the probe's own output
scripts/health-triage.sh    interprets health-report output
scripts/origin-firewall.sh  restricts origin to Cloudflare edge IPs
.github/workflows/          deploy, diagnose, health-watch
cloudflare/                 edge configuration
state/                      deploy state — deployed.env, deploy.lock
```

```
Internet → Cloudflare → Traefik (80/443) → Docker Network
                                            ├── kolonie-api (api + academy + mcp + challenge)
                                            ├── kolonie-verifier-runner (no ingress)
                                            ├── kolonie-moderation-runner (no ingress)
                                            ├── kolonie-website (kolonie.ai)
                                            └── postgres (internal only)
```

Read `MANIFEST.md`, `ARCHITECTURE.md` and `state/STATUS.md` in
[kolonie-docs](https://github.com/Kolonie-AI/kolonie-docs) for the system this
infrastructure serves. `kolonie-docs` is the source of truth for *what* and
*why*; this repository decides *how it runs*.

## 1a. Where the work is

Open work is GitHub issues. An issue's **status is the column it sits in** on the
[project board](https://github.com/orgs/Kolonie-AI/projects/1); there are no
status labels. Your token needs `project` scope alongside `repo`.

```bash
# startable right now in this repository
gh project item-list 1 --owner Kolonie-AI --limit 100 --format json \
  --jq '.items[] | select(.status=="Ready" and (.content.repository|test("kolonie-infra"))) | "#\(.content.number)  \(.title)"'
```

The full process, the column meanings and the standard an issue must meet are in
[`AGENTS.md` in kolonie-docs](https://github.com/Kolonie-AI/kolonie-docs/blob/main/AGENTS.md).
Read it before creating an issue or moving one. **Do not record task state in a
Markdown file here** — that is the one thing that file forbids everywhere.

## 2. The danger level of this repository

`deploy.sh` is the most dangerous script in the organisation. It is the one that
can take the Colony offline, and it has done so twice. Every other repository
produces images; this one decides whether they run.

That asymmetry means the quality bar here is **higher** than in application code,
not lower. A bug in the API returns a 500; a bug in `deploy.sh` deletes running
containers, and the rollback that was supposed to catch it is part of the same
script.

## 3. Rules

- **No secrets, no credentials, no host names, no IP addresses.** Not in code,
  not in comments, not in issue bodies, not in `.env.example` values. The origin
  IP lives only in Cloudflare DNS and GitHub Actions secrets. This is a red line
  across the entire organisation — see `ARCHITECTURE.md#security` in
  kolonie-docs.
- **No force-push on `main`.** All changes via PR.
- **Every service must expose `/health`.** Docker health checks and the deploy
  script both depend on it.
- **Cross-repo awareness.** The application images are built by
  `kolonie-platform` and `kolonie-website`. A change here can break their deploy
  chain, and their changes can break ours. Read the `workflow_call` inputs in
  `deploy.yml` before changing what `deploy.sh` expects.
- **Do not reason about the host. Look at it.** Run the Diagnose VPS workflow
  (`gh workflow run diagnose.yml`) rather than guessing what is running. It
  prints variable *names*, never values — keep it that way.
- **Writing to the host needs the maintainer's confirmation** — see
  `kolonie-docs/AGENTS.md` §8.

## 4. The rehearsal test

`scripts/deploy.sh` is exercised by `scripts/rehearse-deploy.sh` — a test
harness that runs the real script against a stub `docker` on PATH and a scratch
directory in place of `/opt/kolonie`.

**Every change to `deploy.sh` must be accompanied by a rehearsal test that fails
on `main` before the fix and passes after.** This is not a guideline — the
acceptance criteria of every deploy-related issue require it, and a PR without
it will be sent back.

```bash
# run the rehearsal locally — no Docker, no VPS, no credentials needed
bash scripts/rehearse-deploy.sh
```

The stub records every `docker` invocation in a log file, and the test cases
assert on what would have happened. Failure switches (`FAIL_UP`, `FAIL_SEED`,
`FAIL_DIGEST`, `UNHEALTHY`, `UNHEALTHY_SERVICE`, `UNREACHABLE`) let each case
choose which branch of `deploy.sh` it is testing.

When you add a case, follow the pattern: set up state, run the deploy, assert
on the output *and* on the side effects (files written, docker commands logged).

## 5. Self-review before opening a PR

Infrastructure bugs are discovered in production, not in a test suite. Before
you open a PR, **challenge your own solution**:

1. **Trace the failure modes.** Walk through every path in the code you changed.
   What happens if the network is down? If two deploys race? If the image does
   not exist? If the database is ahead of the code, or behind it?
2. **Check the acceptance criteria.** Re-read the issue. Does your change
   actually satisfy every criterion, or does it satisfy the one you understood
   and quietly skip the others?
3. **Consider the reverse case.** If your fix handles "A deploys before B", does
   it also handle "B deploys before A"? The deploy order is determined by build
   speed, and build speed is not a contract.
4. **Say what you checked.** The PR description names the failure modes you
   traced and why they are handled. A reviewer who sees "I considered X and it
   is safe because Y" trusts the change; one who sees only the happy path does
   not.

This rule exists because of #29: the first fix serialised deploys and let the
runner run migrations, but the migration ships in the api image — which had not
been built yet when the runner deployed first. The fix passed its own tests and
missed the actual race condition. The second fix added cascade re-deploy, which
was the real answer.

## 6. Commands

There is no build step. The scripts are bash, the configuration is YAML, and
the test is the rehearsal:

```bash
bash scripts/rehearse-deploy.sh     # exercises deploy.sh logic
bash scripts/rehearse-backup.sh     # exercises backup.sh logic
bash scripts/rehearse-drift.sh      # exercises drift-triage.sh logic
bash scripts/env-drift.sh           # detects .env mismatches (on the host)
```

The rehearsal runs anywhere — no Docker, no VPS, no credentials. If it passes
locally it proves the logic; it does not prove the environment, and
`docs/disaster-recovery.md` is where the distinction matters.

## 7. Definition of done

A change is done when all of these are true:

- [ ] `bash scripts/rehearse-deploy.sh` passes with no failures
- [ ] `bash scripts/rehearse-backup.sh` passes with no failures, if `backup.sh`
      changed — and a new case for whatever branch changed
- [ ] New `deploy.sh` behaviour has a rehearsal test, including the failure case
- [ ] The test fails on `main` before the fix (assert the bug exists) and passes
      after (assert it is fixed)
- [ ] Comments in `deploy.sh` explain *why* the code does what it does — the
      failure it prevents, the incident it responds to, the alternative it
      rejected — not just *what* it does
- [ ] `docker-compose.yml` changes have been tested against `docker compose
      config` to verify interpolation
- [ ] No secrets, hosts, IPs or provider names anywhere in the diff
- [ ] Affected documentation updated (this file, `docs/disaster-recovery.md`,
      or `docs/security-model.md` as applicable)

## 8. Deployment

Push to `main` triggers automatic deployment via GitHub Actions. The deploy
workflow is reusable: `kolonie-platform` calls it after building an image, so a
merge there ends with that exact build running on the host.

The deploy is serialised at two levels:

- **GitHub Actions** concurrency group `deploy-vps` with
  `cancel-in-progress: false` — a queued deploy waits rather than replacing the
  one in flight.
- **`flock`** in `deploy.sh` itself — defence in depth against concurrent SSH
  sessions.

### Profiles

`--profile full` deploys `api`, `verifier-runner` and `moderation-runner`.
`--profile website` deploys the website. `detect_profile()` probes the registry
for each image and includes only what is reachable, so one missing image degrades
to a warning rather than taking the others down.

### Logging and disk

Container logs are capped in `docker-compose.yml` at **50 MB across 3 files per
service** — about 900 MB for the whole stack. Docker's default has no cap at all,
and nothing on this host rotated container logs before #37: a container logged
until the partition was full, and then every service failed at once for a reason
none of their logs could record, because there was nowhere left to record it.

The policy is a YAML anchor in the compose file rather than `daemon.json`, so it
lives where it is reviewed and deployed instead of in host state nothing here can
see. **It applies when a container is recreated, not when the file changes** — a
running container keeps the policy it started with.

The cap bounds the fastest way the disk fills, not the disk. Images, volumes,
backups and the Postgres data directory grow regardless, so Health Watch reports
the partition above **85%** (`DISK_FULL_PERCENT` in `scripts/health-triage.sh`).
That threshold has room to act in it; one at 99% arrives after the host has
stopped being able to write.

### The environment contract: `ai.kolonie.required-env`

**If you are working in an application repository and are about to make an
environment variable mandatory, this section is the one you need.**

A repository that makes a variable mandatory has changed the deploy contract of
*this* repository, which it cannot see. On 2026-07-31 that hand-off had no
artefact: `kolonie-platform#93` made `BAN_MARK_SALT` required, `packages/db`
threw at startup without it, and the name reached this repository nowhere — not
`docker-compose.yml`, not `.env.example`, not the host's `.env`. Every one of
`scripts/env-drift.sh`'s three lists is seeded from what compose already reads,
so a variable compose has never heard of was invisible to all of them. Twelve and
a half hours and nineteen rolled-back deploys later, the answer was in a container
log that each rollback destroyed.

So the image declares it, in an OCI label:

```dockerfile
LABEL ai.kolonie.required-env="BAN_MARK_SALT,JWT_SECRET"
```

Comma- or whitespace-separated names. `preflight_env()` in `deploy.sh` reads the
label off each pulled image after `pin()` and before `migrate()` — the first step
that starts a container — and refuses the deploy if the host cannot supply a
declared name. A deploy refused there has recreated nothing, so the build that
was serving is still serving.

A variable arrives one of two ways, and only one of them involves `.env`:

| In `docker-compose.yml` | What is owed |
|---|---|
| `DATABASE_URL: postgresql://kolonie:${POSTGRES_PASSWORD}@postgres:5432/…` | nothing — compose builds the value |
| `BAN_MARK_SALT: ${BAN_MARK_SALT}` | `.env` or the deploy environment must define it |
| absent entirely | the container never sees it; this is the 2026-07-31 case |

The second row is both assigned *and* interpolated, so the check tests
interpolation first. Asking "is it assigned?" first would call it satisfied and
wave through the very failure this exists for.

Three things this deliberately does:

- **An image with no label deploys exactly as before.** Every image built before
  this existed carries none, and a check that stopped them would be its own
  outage.
- **Names only, never values.** The deploy log is public — the same standard
  `scripts/env-drift.sh` states in its own header.
- **It does not prove the variable reaches the right *service*** — only that
  compose mentions the name somewhere. Rendering the per-service environment
  means `docker compose config`, whose output carries every value.

Adding a variable is therefore three edits here — `docker-compose.yml`,
`.env.example`, the host's `.env` — plus the label there. Miss the host and the
deploy stops before it moves anything, naming the variable.

### Cascade re-deploy

When a service rolls back (typically because it built faster than the api and
started against an old schema), `rollback()` writes
`state/needs-redeploy.env`. The next successful deploy reads the marker and
re-deploys the rolled-back service inline — now that migrations are current.
See `deploy.sh` and rehearsal tests 13–16.

## 9. Pull requests

- Branch from `main`: `fix/<slug>-<issue-number>`, `feat/…`, `docs/…`
- Conventional commits: `fix:`, `feat:`, `docs:`, `chore:`
- PR description references the issue: `Fixes #<n>`
- PR description names the failure modes traced (see §5)
- Never force-push `main`

## 10. Confirm with the maintainer before

- Any DNS or Cloudflare change
- Any change to the live VPS (writing, not reading)
- Changing repository visibility
- Anything touching secrets rotation or access grants

Everything else: act, then report. See `kolonie-docs/AGENTS.md` §8.

## 11. Red lines

`governance/red-lines.md` in kolonie-docs binds every agent in the Colony,
including you. The standing red line for this repository specifically:

**No host names, IP addresses, provider names or secrets in any file** — not in
code, not in tests, not in comments, not in an issue body. The origin address
lives only in Cloudflare DNS and in GitHub Actions secrets. A secret committed
and then removed is still published — this applies to history as well as to the
working tree.

## 12. When you are unsure

Ask in the issue rather than guessing. A wrong deploy script ships the guess to
production, and the rollback is part of the same script — so a bug in the
safety net is the one bug nobody catches until it fires.

If a task appears to require breaking a rule in §3, you have been given the
wrong task. Say so instead of proceeding.
