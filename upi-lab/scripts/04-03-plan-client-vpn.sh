#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
PLAN_FILE="$TERRAFORM_DIR/client-vpn.tfplan"
PENDING_PLAN="$PLAN_FILE.pending"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

for command_name in aws jq terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done
[[ -s "$CERTIFICATE_ARN_FILE" ]] \
  || lab_safety_error "Missing ACM certificate ARN file: $CERTIFICATE_ARN_FILE"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

certificate_arn="$(<"$CERTIFICATE_ARN_FILE")"
[[ "$certificate_arn" =~ ^arn:aws:acm:${AWS_REGION_NAME}:${TF_VAR_expected_account_id}:certificate/[0-9a-f-]+$ ]] \
  || lab_safety_error 'ACM ARN does not belong to the registered account and fixed lab region.'

[[ ! -e "$PLAN_FILE" && ! -e "$PENDING_PLAN" ]] || {
  printf 'ERROR: A Client VPN Plan already exists. Apply or explicitly discard it before replanning.\n' >&2
  exit 1
}

expected_network_state="$(cat <<'EOF'
aws_eip.nat_a
aws_internet_gateway.lab
aws_nat_gateway.a
aws_route.private_default
aws_route.public_default
aws_route_table.private
aws_route_table.public
aws_route_table_association.cluster["cluster-a"]
aws_route_table_association.cluster["cluster-b"]
aws_route_table_association.cluster["cluster-c"]
aws_route_table_association.infra["infra-a"]
aws_route_table_association.infra["infra-b"]
aws_route_table_association.infra["infra-c"]
aws_route_table_association.public["public-a"]
aws_route_table_association.public["public-b"]
aws_route_table_association.public["public-c"]
aws_subnet.cluster["cluster-a"]
aws_subnet.cluster["cluster-b"]
aws_subnet.cluster["cluster-c"]
aws_subnet.infra["infra-a"]
aws_subnet.infra["infra-b"]
aws_subnet.infra["infra-c"]
aws_subnet.public["public-a"]
aws_subnet.public["public-b"]
aws_subnet.public["public-c"]
aws_vpc.lab
EOF
)"
state_list="$(lab_state_list_required "$TERRAFORM_DIR")" || exit 1
actual_managed_state="$(printf '%s' "$state_list" |
  grep -v '^data\.' | LC_ALL=C sort || true)"
[[ "$actual_managed_state" == "$(LC_ALL=C sort <<<"$expected_network_state")" ]] || {
  printf 'ERROR: Client VPN planning requires exactly the validated 26-resource Network state and no resources from later construction stages.\n' >&2
  exit 1
}

export TF_VAR_enable_client_vpn=true
export TF_VAR_client_vpn_server_certificate_arn="$certificate_arn"

expected_actions="$(cat <<'EOF'
aws_cloudwatch_log_group.client_vpn[0]:create
aws_cloudwatch_log_stream.client_vpn[0]:create
aws_ec2_client_vpn_authorization_rule.vpc[0]:create
aws_ec2_client_vpn_endpoint.lab[0]:create
aws_ec2_client_vpn_network_association.infra_a[0]:create
aws_ec2_client_vpn_network_association.infra_b[0]:create
aws_security_group.client_vpn[0]:create
EOF
)"

cleanup_pending_plan() { rm -f -- "$PENDING_PLAN"; }
trap cleanup_pending_plan EXIT
terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PENDING_PLAN"

if ! lab_assert_exact_plan_actions "$TERRAFORM_DIR" "$PENDING_PLAN" "$expected_actions"; then
  printf 'The rejected temporary Plan will be removed; no applyable client-vpn.tfplan was saved.\n' >&2
  exit 1
fi

mv -- "$PENDING_PLAN" "$PLAN_FILE"
trap - EXIT
printf 'Client VPN Plan validation PASSED.\n'
printf 'Expected summary: 7 to add, 0 to change, 0 to destroy.\n'
printf 'Two target-network associations will be created in separate availability zones.\n'
printf 'Saved plan: %s\n' "$PLAN_FILE"
printf 'Next: review the saved Plan before Apply:\n'
printf '  terraform -chdir=%q show -no-color %q\n' "$TERRAFORM_DIR" "$PLAN_FILE"
printf 'After the review passes: bash scripts/04-04-apply-client-vpn.sh\n'
