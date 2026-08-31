#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
PLAN_FILE="$TERRAFORM_DIR/cluster-nodes.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context

[[ -s "$PLAN_FILE" ]] || {
  printf 'ERROR: Missing saved node plan: %s\n' "$PLAN_FILE" >&2
  exit 1
}

changes_json="$(phase6_managed_plan_changes_json "$PLAN_FILE")"
phase6_assert_node_plan "$changes_json"
phase6_assert_plan_account "$PLAN_FILE"
printf 'Validated saved Plan: exactly seven approved RHCOS instance creates.\n'

read -r -p 'Type APPLY-OPENSHIFT-NODES to start all seven RHCOS instances: ' CONFIRM
if [[ "$CONFIRM" != 'APPLY-OPENSHIFT-NODES' ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"
printf 'Started the OpenShift nodes and removed the consumed plan file.\n'
printf 'Do not regenerate Ignition or interrupt the bootstrap sequence.\n'
printf 'Next: bash scripts/06-08-validate-cluster-nodes.sh\n'
