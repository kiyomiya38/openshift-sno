#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
PLAN_FILE="$TERRAFORM_DIR/network.tfplan"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

[[ -s "$PLAN_FILE" ]] || lab_safety_error "Missing saved Network Plan: $PLAN_FILE"
lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

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
lab_assert_exact_plan_actions "$TERRAFORM_DIR" "$PLAN_FILE" "$expected_actions" \
  || lab_safety_error 'Saved Network Plan is not the exact approved 26-create Plan.'

planned_account="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -er '.variables.expected_account_id.value')"
[[ "$planned_account" == "$TF_VAR_expected_account_id" ]] \
  || lab_safety_error 'Saved Network Plan account does not match the registered account.'

read -r -p 'Type APPLY-NETWORK to create exactly 26 network resources: ' CONFIRM
if [[ "$CONFIRM" != APPLY-NETWORK ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"
printf 'Network apply completed and the consumed Plan was removed.\n'
printf 'Next: bash scripts/03-03-validate-network.sh\n'
