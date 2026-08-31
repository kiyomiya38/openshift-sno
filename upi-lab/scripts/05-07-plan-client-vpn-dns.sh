#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
PLAN_FILE="$TERRAFORM_DIR/client-vpn-dns.tfplan"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "${AWS_REGION_NAME:-ap-northeast-3}"

state_list="$(lab_state_list_required "$TERRAFORM_DIR")" || exit 1
if grep -q '^aws_vpc_dhcp_options\.cluster\[' <<<"$state_list"; then
  printf 'ERROR: The OpenShift installation stage already uses the BIND-backed DHCP options. Do not rerun the Client VPN DNS switch planner.\n' >&2
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
export TF_VAR_client_vpn_dns_servers='["10.80.40.11","10.80.50.11"]'

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PLAN_FILE"

planned_changes="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -c '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | {address, actions: .change.actions}]')"
expected_changes='[{"address":"aws_ec2_client_vpn_endpoint.lab[0]","actions":["update"]}]'

printf '\nSaved plan: %s\n' "$PLAN_FILE"
printf 'Managed resource actions:\n'
jq -r '.[] | [.address, (.actions | join(","))] | @tsv' <<<"$planned_changes"

if [[ "$planned_changes" != "$expected_changes" ]]; then
  printf 'ERROR: Expected only an in-place Client VPN endpoint update. Do not apply this plan.\n' >&2
  exit 1
fi

printf 'Client VPN DNS plan validation PASSED.\n'
printf 'Expected summary: 0 to add, 1 to change, 0 to destroy.\n'
printf 'Next: review the saved Plan before Apply:\n'
printf '  terraform -chdir=%q show -no-color %q\n' "$TERRAFORM_DIR" "$PLAN_FILE"
printf 'After the review passes: bash scripts/05-08-apply-client-vpn-dns.sh\n'
