#!/bin/bash
# temporary probe (#69): which single setting does the plan refuse
set -uo pipefail
API="https://api.uptimerobot.com/v3"
H=(-H "Authorization: Bearer ${UPTIMEROBOT_API_KEY}" -H "Content-Type: application/json")
mid=$(curl -s "${H[@]}" "$API/monitors?limit=50" | jq -r '[.data[] | select(.url=="https://academy.kolonie.ai/health")][0].id')
echo "academy monitor id: $mid"
contacts=$(curl -s "${H[@]}" "$API/alert-contacts" | jq -c '[.data[] | select(.status=="Active") | {alertContactId: .id, threshold: 0, recurrence: 0}]')
echo "contacts: $contacts"
try() {
  local label="$1" body="$2"
  printf '%-28s %s\n' "$label" "$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X PATCH -d "$body" "$API/monitors/$mid")"
}
try "assignedAlertContacts" "{\"assignedAlertContacts\":$contacts}"
try "sslExpirationReminder"  '{"sslExpirationReminder":true}'
try "type KEYWORD"           '{"type":"KEYWORD","keywordType":"ALERT_NOT_EXISTS","keywordValue":"\"status\":\"ok\"","keywordCaseType":"CaseSensitive"}'
try "friendlyName+interval"  '{"friendlyName":"kolonie academy /health","interval":300,"timeout":30}'
echo "--- final state ---"
curl -s "${H[@]}" "$API/monitors?limit=50" | jq -c --arg id "$mid" '[.data[] | select((.id|tostring)==$id)][0] | {id,type,status,interval,timeout,checkSSLErrors,sslExpirationReminder,keywordType,keywordValue,contacts:[.assignedAlertContacts[]?.alertContactId]}'
