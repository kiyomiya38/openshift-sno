#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
PLAN_FILE="$TERRAFORM_DIR/client-vpn.tfplan"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

[[ -s "$PLAN_FILE" ]] || lab_safety_error "Missing saved Client VPN Plan: $PLAN_FILE"
lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

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
lab_assert_exact_plan_actions "$TERRAFORM_DIR" "$PLAN_FILE" "$expected_actions" \
  || lab_safety_error 'Saved Client VPN Plan is not the exact approved 7-create Plan.'

plan_json="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE")"
planned_account="$(jq -er '.variables.expected_account_id.value' <<<"$plan_json")"
planned_certificate_arn="$(jq -er '.variables.client_vpn_server_certificate_arn.value' <<<"$plan_json")"
[[ "$planned_account" == "$TF_VAR_expected_account_id" ]] \
  || lab_safety_error 'Saved Client VPN Plan account does not match the registered account.'
[[ "$planned_certificate_arn" =~ ^arn:aws:acm:${AWS_REGION_NAME}:${TF_VAR_expected_account_id}:certificate/[0-9a-f-]+$ ]] \
  || lab_safety_error 'Saved Client VPN Plan has an unexpected certificate ARN.'

read -r -p 'Type APPLY-CLIENT-VPN to create exactly seven Client VPN resources: ' CONFIRM
if [[ "$CONFIRM" != APPLY-CLIENT-VPN ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"
printf 'Client VPN apply completed and the consumed Plan was removed.\n'
printf 'Next: bash scripts/05-validate-client-vpn.sh\n'
