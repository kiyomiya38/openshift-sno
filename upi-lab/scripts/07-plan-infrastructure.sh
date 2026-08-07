#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
PLAN_FILE="$TERRAFORM_DIR/infrastructure.tfplan"
# shellcheck source=lib/phase4-common.sh
source "$SCRIPT_DIR/lib/phase4-common.sh"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE"
TF_VAR_expected_account_id="${TF_VAR_expected_account_id:?Expected AWS account was not exported}"
export TF_VAR_expected_account_id
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "${AWS_REGION_NAME:-ap-northeast-3}"

[[ ! -e "$PLAN_FILE" && ! -e "$PLAN_FILE.pending" ]] || {
  printf 'ERROR: An Infrastructure Plan already exists. Apply or explicitly discard it before replanning.\n' >&2
  exit 1
}

managed_count="$(terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null |
  grep -vc '^data\.' || true)"
[[ "$managed_count" == 33 ]] || {
  printf 'ERROR: Clean Phase 4 planning requires exactly 33 managed Network and Client VPN resources; found %s.\n' "$managed_count" >&2
  printf 'Use the partial-state cleanup procedure instead of planning across phases.\n' >&2
  exit 1
}

if terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null | grep -q '^aws_vpc_dhcp_options\.cluster\['; then
  printf 'ERROR: Phase 6 cluster prerequisites already exist. This Phase 4 planner would omit active Phase 6 flags.\n' >&2
  printf 'Use the dedicated Phase 6 scripts or scripts/11-plan-destroy.sh.\n' >&2
  exit 1
fi

[[ -s "$CERTIFICATE_ARN_FILE" ]] || {
  printf 'ERROR: Missing ACM ARN file: %s\n' "$CERTIFICATE_ARN_FILE" >&2
  exit 1
}
[[ -s "$HOME/.ssh/openshift_upi_lab.pub" ]] || {
  printf 'ERROR: Missing SSH public key: %s\n' "$HOME/.ssh/openshift_upi_lab.pub" >&2
  exit 1
}

export TF_VAR_enable_client_vpn=true
export TF_VAR_client_vpn_server_certificate_arn
TF_VAR_client_vpn_server_certificate_arn="$(<"$CERTIFICATE_ARN_FILE")"
export TF_VAR_enable_infrastructure_services=true

PENDING_PLAN="$PLAN_FILE.pending"
trap 'rm -f -- "$PENDING_PLAN"' EXIT
terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PENDING_PLAN"

if ! phase4_assert_exact_plan "$TERRAFORM_DIR" "$PENDING_PLAN"; then
  printf 'The rejected temporary Plan will be removed; no applyable infrastructure.tfplan was saved.\n' >&2
  exit 1
fi
mv -- "$PENDING_PLAN" "$PLAN_FILE"
trap - EXIT

printf '\nSaved plan: %s\n' "$PLAN_FILE"
printf 'Review resource actions before applying:\n'
terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | [.address, (.change.actions | join(","))] | @tsv'
printf 'Infrastructure Plan validation PASSED.\n'
printf 'Expected summary: 56 to add, 0 to change, 0 to destroy.\n'
printf 'Next: bash scripts/07b-apply-infrastructure.sh\n'
