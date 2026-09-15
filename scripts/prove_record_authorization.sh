#!/usr/bin/env bash
# Full proof, including negative controls and explanatory traces. Test stack only.
set -euo pipefail
cd "$(dirname "$0")/.."
proof_root="$PWD/reports/raw/record-authorization"
export PROOF_OUTPUT_ROOT="$proof_root"
export PROOF_MUTATION_OUTPUT="$proof_root/mutations"
bash scripts/test_record_authorization_matrix.sh
python3 scripts/test_record_authorization_mutations.py
mkdir -p "$proof_root/schema"
for service in account-service user-service group-service organization-service authorization-service user-management-service; do
  cp "$proof_root/capabilities-true/graphql-$service.json" "$proof_root/schema/graphql-$service.json"
done
./dc_test up -d jaeger otel-collector
for mode in can capabilities; do
  mkdir -p "$proof_root/traces/$mode"
  AUTHORIZATION_CHECK_MODE="$mode" GLOBAL_IAM_DEMO_USE_REDIS=true \
    PROOF_SKIP_SEED=1 PROOF_SKIP_ROUTES=1 PROOF_SKIP_EXISTING=1 PROOF_TRACE_DRIVER=1 \
    PROOF_OUTPUT="$proof_root/traces/$mode" bash scripts/test_record_authorization.sh \
    > "$proof_root/traces/$mode/run.log" 2>&1
done
python3 scripts/summarize_record_authorization.py
