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

post_state_list="$(lab_state_list_required "$TERRAFORM_DIR")" \
  || phase6_error 'Bootstrap removal was applied, but Terraform state could not be verified.'
remaining_bootstrap="$(printf '%s' "$post_state_list" |
  grep -Fxc 'aws_instance.openshift["bootstrap"]' || true)"
[[ "$remaining_bootstrap" == 0 ]] || {
  printf 'ERROR: Bootstrap remains in Terraform state.\n' >&2
  exit 1
}

expected_permanent_nodes="$(cat <<'EOF'
aws_instance.openshift["control-plane-0"]
aws_instance.openshift["control-plane-1"]
aws_instance.openshift["control-plane-2"]
aws_instance.openshift["worker-0"]
aws_instance.openshift["worker-1"]
aws_instance.openshift["worker-2"]
EOF
)"
actual_permanent_nodes="$(printf '%s' "$post_state_list" |
  grep '^aws_instance\.openshift\[' | LC_ALL=C sort || true)"
[[ "$actual_permanent_nodes" == "$expected_permanent_nodes" ]] || {
  printf 'ERROR: Terraform state does not contain exactly the six permanent OpenShift nodes.\n' >&2
  printf '%s\n' '--- Expected OpenShift instances ---' >&2
  printf '%s\n' "$expected_permanent_nodes" >&2
  printf '%s\n' '--- Actual OpenShift instances ---' >&2
  printf '%s\n' "${actual_permanent_nodes:-<none>}" >&2
  exit 1
}

printf 'Bootstrap removal PASSED. Six permanent OpenShift nodes remain.\n'
printf 'Next: bash scripts/06-13-review-csrs.sh\n'
