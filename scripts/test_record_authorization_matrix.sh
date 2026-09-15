#!/usr/bin/env bash
# Complete normal proof: both authorization protocols, Redis off/on. Each
# example repeats decisions after warming caches; existing boundary tests follow.
set -euo pipefail
cd "$(dirname "$0")/.."
proof_root="${PROOF_OUTPUT_ROOT:-$PWD/reports/raw/record-authorization}"
for mode in can capabilities; do
  for redis in false true; do
    profile="$mode-$redis"
    mkdir -p "$proof_root/$profile"
    AUTHORIZATION_CHECK_MODE="$mode" GLOBAL_IAM_DEMO_USE_REDIS="$redis" \
      PROOF_OUTPUT="$proof_root/$profile" bash scripts/test_record_authorization.sh \
      > "$proof_root/$profile/run.log" 2>&1
  done
done
