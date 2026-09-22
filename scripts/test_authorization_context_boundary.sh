#!/usr/bin/env bash
set -euo pipefail

./dc_test up -d account-db account-service

base_url="http://127.0.0.1:${ACCOUNT_SERVICE_WEB_PORT:-11100}"
target_id="00000000-0000-4000-8000-000000000000"

ready=false
for _attempt in {1..60}; do
  if curl -fsS -o /dev/null "${base_url}/up"; then
    ready=true
    break
  fi
  sleep 0.5
done
test "$ready" = "true"

forged_status="$(curl -sS -o /tmp/iam-context-forged.json -w '%{http_code}' \
  -H 'pad-user-id: IAM_SYSTEM' \
  -H 'X-IAM-Authorization-Scope: iam' \
  "${base_url}/accounts/${target_id}")"
test "$forged_status" = "403"

authenticated_status="$(curl -sS -o /tmp/iam-context-authenticated.json -w '%{http_code}' \
  -H 'pad-user-id: IAM_SYSTEM' \
  -H 'X-IAM-Authorization-Scope: iam' \
  -H "X-IAM-Internal-Token: ${IAM_INTERNAL_TOKEN:-test-only-iam-internal-token}" \
  "${base_url}/accounts/${target_id}")"
test "$authenticated_status" = "404"

echo "authorization-context service boundary: forged=403 authenticated=404"
