#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
PLAN_FILE="$TERRAFORM_DIR/destroy.tfplan"
PLAN_META_FILE="$TERRAFORM_DIR/destroy.tfplan.meta"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

for command_name in aws flock jq sha256sum terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id legacy "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "${AWS_REGION_NAME:-ap-northeast-3}"
lab_assert_no_recovery_or_active_test

[[ ! -e "$PLAN_FILE" && ! -e "$PLAN_META_FILE" ]] || {
  printf 'ERROR: A destroy Plan or its guard metadata already exists.\n' >&2
  printf 'Apply it, or explicitly remove both files before creating a new Plan.\n' >&2
  exit 1
}

state_list="$(terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null || true)"
managed_state="$(grep -v '^data\.' <<<"$state_list" | sed '/^$/d')"
managed_count="$(wc -l <<<"$managed_state" | tr -d ' ')"
[[ -n "$managed_state" ]] || {
  printf 'No managed Terraform resources remain. No destroy Plan was created.\n'
  printf 'Next: bash scripts/13-delete-client-vpn-certificate.sh\n'
  exit 0
}

while IFS= read -r address; do
  base_address="${address%%\[*}"
  case "$base_address" in
    aws_vpc.lab | aws_internet_gateway.lab | aws_subnet.cluster | aws_subnet.infra | aws_subnet.public | \
    aws_route_table.public | aws_route.public_default | aws_route_table_association.public | \
    aws_eip.nat_a | aws_nat_gateway.a | aws_route_table.private | aws_route.private_default | \
    aws_route_table_association.cluster | aws_route_table_association.infra | \
    aws_cloudwatch_log_group.client_vpn | aws_cloudwatch_log_stream.client_vpn | \
    aws_security_group.client_vpn | aws_ec2_client_vpn_endpoint.lab | \
    aws_ec2_client_vpn_network_association.infra_a | aws_ec2_client_vpn_network_association.infra_b | \
    aws_ec2_client_vpn_authorization_rule.vpc | \
    aws_key_pair.infrastructure | aws_iam_role.infrastructure | aws_iam_role_policy_attachment.ssm | \
    aws_iam_instance_profile.infrastructure | aws_security_group.infrastructure_admin | \
    aws_vpc_security_group_ingress_rule.admin_ssh_from_vpn | aws_security_group.dns_ntp | \
    aws_vpc_security_group_ingress_rule.dns_udp_from_vpc | aws_vpc_security_group_ingress_rule.dns_tcp_from_vpc | \
    aws_vpc_security_group_ingress_rule.dns_udp_from_vpn | aws_vpc_security_group_ingress_rule.dns_tcp_from_vpn | \
    aws_vpc_security_group_ingress_rule.ntp_udp_from_vpc | aws_security_group.haproxy | \
    aws_vpc_security_group_ingress_rule.haproxy_vpc | aws_security_group.proxy_registry | \
    aws_vpc_security_group_ingress_rule.proxy_from_vpc | aws_vpc_security_group_ingress_rule.registry_from_vpc | \
    aws_security_group.nfs | aws_vpc_security_group_ingress_rule.nfs_from_vpc | aws_instance.infrastructure | \
    aws_security_group.internal_nlb | aws_vpc_security_group_ingress_rule.nlb_from_vpc | \
    aws_vpc_security_group_ingress_rule.nlb_from_vpn | aws_lb.openshift_internal | \
    aws_lb_target_group.openshift | aws_lb_target_group_attachment.haproxy | aws_lb_listener.openshift | \
    aws_vpc_dhcp_options.cluster | aws_vpc_dhcp_options_association.cluster | \
    aws_security_group.openshift_nodes | aws_security_group.ignition_server | \
    aws_security_group.openshift_control_plane | aws_security_group.openshift_worker | \
    aws_vpc_security_group_ingress_rule.openshift_nodes_from_self | \
    aws_vpc_security_group_ingress_rule.openshift_ssh_from_vpn | \
    aws_vpc_security_group_ingress_rule.openshift_ssh_from_infrastructure | \
    aws_vpc_security_group_ingress_rule.openshift_from_haproxy | \
    aws_vpc_security_group_ingress_rule.ignition_http_from_nodes | aws_instance.openshift)
      ;;
    *)
      printf 'ERROR: Terraform state contains an address outside the lab allowlist: %s\n' "$address" >&2
      exit 1
      ;;
  esac
done <<<"$managed_state"

PENDING_PLAN="$PLAN_FILE.pending"
trap 'rm -f -- "$PENDING_PLAN"' EXIT
terraform -chdir="$TERRAFORM_DIR" plan -destroy -input=false -out="$PENDING_PLAN"

unexpected_actions="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PENDING_PLAN" |
  jq -r '[.resource_changes[]? | select(.mode == "managed") |
    select(.change.actions != ["delete"] and .change.actions != ["no-op"])] | length')"
delete_count="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PENDING_PLAN" |
  jq -r '[.resource_changes[]? | select(.mode == "managed" and .change.actions == ["delete"])] | length')"
[[ "$unexpected_actions" == 0 && "$delete_count" == "$managed_count" ]] || {
  printf 'ERROR: Destroy Plan must contain exactly %s managed deletes and no other managed actions.\n' "$managed_count" >&2
  printf 'Found deletes=%s, unexpected=%s. The temporary Plan will be removed.\n' "$delete_count" "$unexpected_actions" >&2
  exit 1
}

mv -- "$PENDING_PLAN" "$PLAN_FILE"
trap - EXIT

printf '\nSaved destroy plan: %s\n' "$PLAN_FILE"
terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -r '[((.resource_changes // [])[].change.actions[])] | group_by(.) | map({action: .[0], count: length})'

printf 'Destroy plan validation PASSED: %s managed resources will be deleted.\n' "$delete_count"
printf 'This count is derived from the current state and is valid for partial or complete builds.\n'

workspace_name="$(terraform -chdir="$TERRAFORM_DIR" workspace show)"
state_identity="$(terraform -chdir="$TERRAFORM_DIR" state pull |
  jq -er '[.lineage, (.serial | tostring)] | @tsv')"
IFS=$'\t' read -r state_lineage state_serial <<<"$state_identity"
plan_sha256="$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
{
  printf 'ACCOUNT_ID=%q\n' "$TF_VAR_expected_account_id"
  printf 'AWS_REGION=%q\n' "${AWS_REGION_NAME:-ap-northeast-3}"
  printf 'WORKSPACE=%q\n' "$workspace_name"
  printf 'STATE_LINEAGE=%q\n' "$state_lineage"
  printf 'STATE_SERIAL=%q\n' "$state_serial"
  printf 'PLAN_SHA256=%q\n' "$plan_sha256"
  printf 'DELETE_COUNT=%q\n' "$delete_count"
} >"$PLAN_META_FILE"
chmod 600 "$PLAN_META_FILE"
printf 'Destroy plan guard metadata: %s\n' "$PLAN_META_FILE"
