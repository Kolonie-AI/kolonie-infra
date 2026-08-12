#!/bin/bash
# Kolonie AI — where the Telegram webhook is registered (kolonie-platform#795)
#
#   ./scripts/telegram-webhook.sh report   what Telegram currently has
#   ./scripts/telegram-webhook.sh apply    register this deployment's route
#   ./scripts/telegram-webhook.sh delete   stop deliveries
#
# ## Why this is a step and not something the API does on boot
#
# `setWebhook` is idempotent and would be easy to call at startup — and that is
# exactly what makes it the wrong place. A registration made from inside the
# process points Telegram at whatever host that process believes it is on, so a
# second deployment, a staging copy or a container started on a laptop with the
# production token would take delivery of every operator's replies, silently and
# from the other side. **Which host receives them is a deployment decision**, so
# it is taken here, once, by somebody who can see which host they mean.
#
# `kolonie-platform#795` requires this to exist and to be findable, in those
# words: *"say where it lives, so it is not discovered later as the one manual
# step nobody wrote down."*
#
# ## Reading, not committing
#
# The token and the secret are read from the host's `.env`, which is `600` and is
# the only place they exist. **Nothing here prints either**, and the URL is
# composed from `API_URL` rather than written down: the origin is a host of ours
# and `AGENTS.md` §11 keeps host names out of this repository.
#
# `API_URL` had no reader until this file — `env-drift.sh` listed it under
# *documented but read by no service*. It is the API's own public origin, which
# is exactly what Telegram has to be pointed at, so this is the reader that entry
# was waiting for rather than a new variable.
set -uo pipefail

ENV_FILE=${ENV_FILE:-/opt/kolonie/.env}
COMMAND=${1:-report}

# The one path the API mounts for this (`apps/api/src/routes/telegram.ts`). It is
# under `/v1/internal/` and behind the secret header, like the mail inbound route.
WEBHOOK_PATH=${WEBHOOK_PATH:-/v1/internal/telegram-updates}

# **`message` and `edited_message`, and nothing else.** The default subscribes to
# update types this bot has no use for, and every one of them is a delivery, a
# retry budget and a line in a log. The edit is subscribed to deliberately: the
# bot answers an edit by saying that what was recorded has not changed, and an
# unsubscribed edit would be silence to somebody who thinks they have corrected
# themselves.
#
# **Assigned in two lines and not as a `${VAR:-default}`**, which is not style: the
# default is JSON, `${VAR:-["a","b"]}` strips the inner quotes, and `jq --argjson`
# then fails on `[message,edited_message]` — leaving `curl` to POST an empty body
# and Telegram to answer that no url was given. Found by running the script
# against a fixture `.env` before it was ever run against the real one.
ALLOWED_UPDATES=${ALLOWED_UPDATES:-}
[ -n "$ALLOWED_UPDATES" ] || ALLOWED_UPDATES='["message","edited_message"]'

value_of() {
  local name=$1
  # Names only ever reach the output of this script; values never do.
  sed -n "s/^${name}=//p" "$ENV_FILE" 2>/dev/null | tail -1 | sed 's/^"//; s/"$//'
}

[ -r "$ENV_FILE" ] || {
  echo "FAIL: cannot read $ENV_FILE — run this on the deploy host" >&2
  exit 1
}

TOKEN=$(value_of TELEGRAM_OPERATOR_BOT_TOKEN)
SECRET=$(value_of TELEGRAM_WEBHOOK_SECRET)
BASE=$(value_of API_URL)

for required in TELEGRAM_OPERATOR_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET API_URL; do
  case "$required" in
    TELEGRAM_OPERATOR_BOT_TOKEN) held=$TOKEN ;;
    TELEGRAM_WEBHOOK_SECRET) held=$SECRET ;;
    *) held=$BASE ;;
  esac
  [ -n "$held" ] || {
    echo "FAIL: $required is not set in $ENV_FILE" >&2
    exit 1
  }
done

api() {
  local method=$1
  shift
  curl -sS -X POST "https://api.telegram.org/bot${TOKEN}/${method}" \
    -H 'content-type: application/json' \
    -d "$1"
}

case "$COMMAND" in
  report)
    # `getWebhookInfo` answers with the URL, the pending count and the last error
    # — which is the whole of what anybody wants to know here. The URL contains no
    # secret; the header does, and Telegram does not echo it back.
    api getWebhookInfo '{}' | jq '.result | {url, pending_update_count, last_error_message, last_error_date}'
    ;;
  apply)
    # **`drop_pending_updates` on the first registration**, because anything queued
    # before the route existed is a delivery to a path that answered 404, and
    # replaying it would answer people who have given up waiting.
    api setWebhook "$(jq -nc \
      --arg url "${BASE%/}${WEBHOOK_PATH}" \
      --arg secret "$SECRET" \
      --argjson updates "$ALLOWED_UPDATES" \
      '{url: $url, secret_token: $secret, allowed_updates: $updates, drop_pending_updates: true}')" |
      jq '{ok, description}'
    ;;
  delete)
    api deleteWebhook '{"drop_pending_updates": true}' | jq '{ok, description}'
    ;;
  *)
    echo "usage: $0 report|apply|delete" >&2
    exit 2
    ;;
esac
