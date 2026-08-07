#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
PLAN_FILE="$TERRAFORM_DIR/infrastructure.tfplan"
# shellcheck source=lib/phase4-common.sh
source "$SCRIPT_DIR/lib/phase4-common.sh"

for command_name in aws jq terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done
[[ -s "$PLAN_FILE" ]] || lab_safety_error "Missing saved Infrastructure Plan: $PLAN_FILE"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
TF_VAR_expected_account_id="${TF_VAR_expected_account_id:?Expected AWS account was not exported}"
export TF_VAR_expected_account_id
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"
phase4_assert_exact_plan "$TERRAFORM_DIR" "$PLAN_FILE" \
  || lab_safety_error 'Saved Infrastructure Plan is not the exact approved 56-create Plan.'

plan_json="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE")"
planned_account="$(jq -er '.variables.expected_account_id.value' <<<"$plan_json")"
planned_certificate_arn="$(jq -er '.variables.client_vpn_server_certificate_arn.value' <<<"$plan_json")"
[[ "$planned_account" == "$TF_VAR_expected_account_id" ]] \
  || lab_safety_error 'Saved Infrastructure Plan account does not match the registered account.'
[[ "$planned_certificate_arn" =~ ^arn:aws:acm:${AWS_REGION_NAME}:${TF_VAR_expected_account_id}:certificate/[0-9a-f-]+$ ]] \
  || lab_safety_error 'Saved Infrastructure Plan has an unexpected Client VPN certificate ARN.'

printf 'Validated action summary: 56 to add, 0 to change, 0 to destroy.\n'
read -r -p 'Type APPLY-INFRASTRUCTURE to continue: ' CONFIRM
if [[ "$CONFIRM" != APPLY-INFRASTRUCTURE ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"
printf 'Infrastructure apply completed and the consumed Plan was removed.\n'
printf 'Next: bash scripts/06-validate-infrastructure.sh\n'
