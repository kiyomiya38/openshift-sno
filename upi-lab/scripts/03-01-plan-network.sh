#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
PLAN_FILE="$TERRAFORM_DIR/network.tfplan"
PENDING_PLAN="$PLAN_FILE.pending"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

for command_name in aws jq terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

[[ ! -e "$PENDING_PLAN" ]] || {
  printf 'ERROR: A temporary Network Plan exists: %s\n' "$PENDING_PLAN" >&2
  printf 'Do not remove it while another Terraform process may be running.\n' >&2
  exit 1
}

managed_count="$(lab_managed_state_count_allow_absent "$TERRAFORM_DIR")"
[[ "$managed_count" == 0 ]] || {
  printf 'ERROR: Network planning is allowed only with an empty managed Terraform state; found %s resources.\n' "$managed_count" >&2
  printf 'Use the planner dedicated to the current construction stage, or the partial-state cleanup procedure.\n' >&2
  exit 1
}

expected_actions="$(cat <<'EOF'
aws_eip.nat_a:create
aws_internet_gateway.lab:create
aws_nat_gateway.a:create
aws_route.private_default:create
aws_route.public_default:create
aws_route_table.private:create
aws_route_table.public:create
aws_route_table_association.cluster["cluster-a"]:create
aws_route_table_association.cluster["cluster-b"]:create
aws_route_table_association.cluster["cluster-c"]:create
aws_route_table_association.infra["infra-a"]:create
aws_route_table_association.infra["infra-b"]:create
aws_route_table_association.infra["infra-c"]:create
aws_route_table_association.public["public-a"]:create
aws_route_table_association.public["public-b"]:create
aws_route_table_association.public["public-c"]:create
aws_subnet.cluster["cluster-a"]:create
aws_subnet.cluster["cluster-b"]:create
aws_subnet.cluster["cluster-c"]:create
aws_subnet.infra["infra-a"]:create
aws_subnet.infra["infra-b"]:create
aws_subnet.infra["infra-c"]:create
aws_subnet.public["public-a"]:create
aws_subnet.public["public-b"]:create
aws_subnet.public["public-c"]:create
aws_vpc.lab:create
EOF
)"

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate

if [[ -s "$PLAN_FILE" ]]; then
  lab_assert_exact_plan_actions "$TERRAFORM_DIR" "$PLAN_FILE" "$expected_actions" \
    || lab_safety_error 'Existing Network Plan is not the exact approved 26-create Plan.'

  planned_account="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
    jq -er '.variables.expected_account_id.value')"
  [[ "$planned_account" == "$TF_VAR_expected_account_id" ]] \
    || lab_safety_error 'Existing Network Plan account does not match the registered account.'

  printf 'Existing Network Plan validation PASSED. No Plan was regenerated or overwritten.\n'
  printf 'Expected summary: 26 to add, 0 to change, 0 to destroy.\n'
  printf 'Saved plan: %s\n' "$PLAN_FILE"
  printf 'Next: review the saved Plan before Apply:\n'
  printf '  terraform -chdir=%q show -no-color %q\n' "$TERRAFORM_DIR" "$PLAN_FILE"
  printf 'After the review passes: bash scripts/03-02-apply-network.sh\n'
  exit 0
fi

cleanup_pending_plan() {
  rm -f -- "$PENDING_PLAN"
}
trap cleanup_pending_plan EXIT

terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PENDING_PLAN"

if ! lab_assert_exact_plan_actions "$TERRAFORM_DIR" "$PENDING_PLAN" "$expected_actions"; then
  printf 'The rejected temporary Plan will be removed; no applyable network.tfplan was saved.\n' >&2
  exit 1
fi

mv -- "$PENDING_PLAN" "$PLAN_FILE"
trap - EXIT
printf 'Network Plan validation PASSED.\n'
printf 'Expected summary: 26 to add, 0 to change, 0 to destroy.\n'
printf 'Saved plan: %s\n' "$PLAN_FILE"
printf 'Next: review the saved Plan before Apply:\n'
printf '  terraform -chdir=%q show -no-color %q\n' "$TERRAFORM_DIR" "$PLAN_FILE"
printf 'After the review passes: bash scripts/03-02-apply-network.sh\n'
