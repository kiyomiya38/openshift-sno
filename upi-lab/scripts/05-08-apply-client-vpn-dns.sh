#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
PLAN_FILE="$TERRAFORM_DIR/client-vpn-dns.tfplan"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "${AWS_REGION_NAME:-ap-northeast-3}"

[[ -s "$PLAN_FILE" ]] || {
  printf 'ERROR: Missing saved plan: %s\n' "$PLAN_FILE" >&2
  printf 'Run scripts/05-07-plan-client-vpn-dns.sh first.\n' >&2
  exit 1
}

plan_json="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE")"
planned_changes="$(jq -c '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | {address, actions: .change.actions}]' <<<"$plan_json")"
expected_changes='[{"address":"aws_ec2_client_vpn_endpoint.lab[0]","actions":["update"]}]'
planned_dns="$(jq -c '.variables.client_vpn_dns_servers.value' <<<"$plan_json")"
planned_account="$(jq -r '.variables.expected_account_id.value' <<<"$plan_json")"
current_account="$TF_VAR_expected_account_id"

[[ "$planned_changes" == "$expected_changes" ]] || {
  printf 'ERROR: Saved plan contains unexpected resource actions. Do not apply.\n' >&2
  exit 1
}
[[ "$planned_dns" == '["10.80.40.11","10.80.50.11"]' ]] || {
  printf 'ERROR: Saved plan does not contain the expected BIND DNS servers. Do not apply.\n' >&2
  exit 1
}
[[ "$planned_account" == "$current_account" ]] || {
  printf 'ERROR: Plan account %s does not match current account %s. Do not apply.\n' "$planned_account" "$current_account" >&2
  exit 1
}

printf 'Plan account: %s\n' "$planned_account"
printf 'Planned DNS servers: %s\n' "$planned_dns"
printf 'Managed resource actions:\n'
jq -r '.[] | [.address, (.actions | join(","))] | @tsv' <<<"$planned_changes"
printf '\nThe active AWS Client VPN session may disconnect during this update.\n'

read -r -p 'Type APPLY-CLIENT-VPN-DNS to continue: ' CONFIRM
if [[ "$CONFIRM" == 'APPLY-CLIENT-VPN-DNS' ]]; then
  terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
  rm -- "$PLAN_FILE"
  printf 'Removed the consumed Client VPN DNS Plan.\n'
  printf 'Next: reconnect the Windows Client VPN, then run scripts/05-09-validate-client-vpn-dns.sh.\n'
else
  printf 'Apply cancelled.\n'
fi
