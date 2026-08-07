#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
PLAN_FILE="$TERRAFORM_DIR/bootstrap-removal.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context

[[ -s "$PLAN_FILE" ]] || {
  printf 'ERROR: Missing saved Bootstrap removal plan: %s\n' "$PLAN_FILE" >&2
  exit 1
}

changes_json="$(phase6_managed_plan_changes_json "$PLAN_FILE")"
phase6_assert_bootstrap_removal_plan "$changes_json"
phase6_assert_plan_account "$PLAN_FILE"
printf 'Validated saved Plan: only the temporary Bootstrap instance will be deleted.\n'

read -r -p 'Type REMOVE-BOOTSTRAP to delete only the temporary Bootstrap EC2 instance: ' CONFIRM
if [[ "$CONFIRM" != 'REMOVE-BOOTSTRAP' ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"

remaining_bootstrap="$(terraform -chdir="$TERRAFORM_DIR" state list | grep -c 'aws_instance\.openshift\["bootstrap"\]' || true)"
[[ "$remaining_bootstrap" == 0 ]] || {
  printf 'ERROR: Bootstrap remains in Terraform state.\n' >&2
  exit 1
}

printf 'Bootstrap removal PASSED. Six permanent OpenShift nodes remain.\n'
printf 'Next: bash scripts/27-review-csrs.sh\n'
