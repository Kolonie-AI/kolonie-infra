#!/bin/bash
# Kolonie AI — the services this organisation builds images for (#107).
#
# Sourced, never run. Defines two things and nothing else:
#
#   KOLONIE_SERVICES        the compose service names, in deploy order
#   KOLONIE_SERVICE_IMAGES  "<service>:<IMAGE_VAR>", for the record in state/deployed.env
#
# ## Why this file exists
#
# It existed twice, and the two copies disagreed. `pin-report.sh` listed six
# services; `deployed-revision.sh` listed four — `api verifier-runner
# moderation-runner website` — and the two it was missing were `badge-runner`
# and `support-triage-runner`.
#
# On 2026-08-09 `badge-runner` failed its health check on every image built after
# `e1a2a08` and thirteen consecutive deploys of `main` rolled back. **The drift
# check ran every fifteen minutes throughout and reported every service
# current**, truthfully, about the four it could see. The service that was
# actually behind was not one of them, and nothing anywhere said so for seven
# hours (`kolonie-infra#107`).
#
# A list that has to be edited in two places is a list that will be edited in
# one. This is the one place.
#
# ## What is deliberately not here
#
# **Upstream images.** Traefik, Postgres, Loki, Promtail and pgAdmin are pinned
# in `docker-compose.yml` to versions this organisation did not build, so they
# carry somebody else's revision and there is no record of intent for them to
# drift from. `pin-report.sh` said this first and it is still the reason.
#
# **The image variable names are irregular and stay irregular.** `verifier-runner`
# is `RUNNER_IMAGE` and `support-triage-runner` is `TRIAGE_IMAGE`, because that is
# what `docker-compose.yml` and `state/deployed.env` already use. A mapping
# derived from the container name would report `unrecorded` forever for exactly
# the two whose names do not follow the pattern — which is the same class of
# silent blindness this file was written to end.
#
# `scripts/check-services.sh` fails when this disagrees with `docker-compose.yml`,
# so adding a service to compose and forgetting this file is caught before it can
# be a monitor that is quietly blind again.

# The compose service names, in the order `deploy.yml` deploys them: the api
# first, because it is what moves the schema, then everything that reads it.
KOLONIE_SERVICES=(
    api
    verifier-runner
    moderation-runner
    support-triage-runner
    badge-runner
    website
)

# The same list, each paired with the variable `state/deployed.env` records its
# pinned digest under.
KOLONIE_SERVICE_IMAGES=(
    "api:API_IMAGE"
    "verifier-runner:RUNNER_IMAGE"
    "moderation-runner:MODERATION_IMAGE"
    "support-triage-runner:TRIAGE_IMAGE"
    "badge-runner:BADGE_IMAGE"
    "website:WEBSITE_IMAGE"
)
