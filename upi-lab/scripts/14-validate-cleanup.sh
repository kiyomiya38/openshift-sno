#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
CLEANUP_MARKER_FILE="${CLEANUP_MARKER_FILE:-$HOME/.config/openshift-upi-lab/cleanup-validated.json}"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
warn() { printf 'WARN: %s\n' "$1"; }

check_empty() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "None" ]]; then
    pass "$label: none"
  else
    fail "$label remains: $value"
  fi
}

for command_name in aws flock jq terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id legacy "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"
lab_assert_no_recovery_or_active_test

if state_json="$(terraform -chdir="$TERRAFORM_DIR" state pull 2>/dev/null)"; then
  state_count="$(jq -r '[.resources[]? | select(.mode == "managed")] | length' <<<"$state_json")"
  state_lineage="$(jq -r '.lineage // "absent"' <<<"$state_json")"
  state_serial="$(jq -r '.serial // 0' <<<"$state_json")"
else
  state_count=0
  state_lineage=absent
  state_serial=0
fi
[[ "$state_count" == 0 ]] && pass 'Terraform state has no managed resources' || fail "Terraform state still has $state_count managed resources"

tagged_resources="$(aws resourcegroupstaggingapi get-resources \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --tag-filters Key=Project,Values=openshift-upi-lab \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text)"
tagged_other_resources="$(tr '\t' '\n' <<<"$tagged_resources" |
  grep -Ev ':instance/|:volume/|:snapshot/|:natgateway/|:security-group-rule/|:vpc/|:subnet/|:route-table/|:internet-gateway/|:network-interface/|:elastic-ip/|:client-vpn-endpoint/|:security-group/|:dhcp-options/|:loadbalancer/|:targetgroup/|:log-group:|:certificate/' || true)"
check_empty 'Tagged resources outside known EC2 deletion cache entries' "$tagged_other_resources"
if [[ -n "$tagged_resources" && -z "$tagged_other_resources" ]]; then
  warn 'Tagging API still caches deleted EC2 ARNs; direct EC2 checks below are authoritative.'
fi

instances="$(aws ec2 describe-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
check_empty 'Non-terminated EC2 instances' "$instances"

volumes="$(aws ec2 describe-volumes \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'Volumes[].VolumeId' --output text)"
check_empty 'EBS volumes' "$volumes"

snapshots="$(aws ec2 describe-snapshots \
  --owner-ids self --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'Snapshots[].SnapshotId' --output text)"
check_empty 'EBS snapshots' "$snapshots"

addresses="$(aws ec2 describe-addresses \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'Addresses[].AllocationId' --output text)"
check_empty 'Elastic IP allocations' "$addresses"

nat_gateways="$(aws ec2 describe-nat-gateways \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filter Name=tag:Project,Values=openshift-upi-lab Name=state,Values=pending,available,deleting,failed \
  --query 'NatGateways[].NatGatewayId' --output text)"
check_empty 'NAT Gateways' "$nat_gateways"

client_vpn="$(aws ec2 describe-client-vpn-endpoints \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'ClientVpnEndpoints[].ClientVpnEndpointId' --output text)"
check_empty 'Client VPN endpoints' "$client_vpn"

vpcs="$(aws ec2 describe-vpcs \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'Vpcs[].VpcId' --output text)"
check_empty 'Lab VPCs' "$vpcs"

subnets="$(aws ec2 describe-subnets \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'Subnets[].SubnetId' --output text)"
check_empty 'Lab subnets' "$subnets"

route_tables="$(aws ec2 describe-route-tables \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'RouteTables[].RouteTableId' --output text)"
check_empty 'Lab route tables' "$route_tables"

internet_gateways="$(aws ec2 describe-internet-gateways \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'InternetGateways[].InternetGatewayId' --output text)"
check_empty 'Internet Gateways' "$internet_gateways"

security_groups="$(aws ec2 describe-security-groups \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'SecurityGroups[].GroupId' --output text)"
check_empty 'Security groups' "$security_groups"

security_group_rules="$(aws ec2 describe-security-group-rules \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'SecurityGroupRules[].SecurityGroupRuleId' --output text)"
check_empty 'Security group rules' "$security_group_rules"

dhcp_options="$(aws ec2 describe-dhcp-options \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'DhcpOptions[].DhcpOptionsId' --output text)"
check_empty 'Custom DHCP options' "$dhcp_options"

load_balancers="$(aws elbv2 describe-load-balancers \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --query 'LoadBalancers[?LoadBalancerName==`openshift-upi-internal`].LoadBalancerArn' --output text)"
check_empty 'Internal NLBs' "$load_balancers"

target_groups="$(aws elbv2 describe-target-groups \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --query 'TargetGroups[?starts_with(TargetGroupName, `upi-`)].TargetGroupArn' --output text)"
check_empty 'OpenShift target groups' "$target_groups"

network_interfaces="$(aws ec2 describe-network-interfaces \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=description,Values='ELB net/openshift-upi-internal/*' \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
check_empty 'Internal NLB network interfaces' "$network_interfaces"

tagged_network_interfaces="$(aws ec2 describe-network-interfaces \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --filters Name=tag:Project,Values=openshift-upi-lab \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
check_empty 'Tagged network interfaces' "$tagged_network_interfaces"

log_groups="$(aws logs describe-log-groups \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --log-group-name-prefix /aws/client-vpn/openshift-upi-lab \
  --query 'logGroups[].logGroupName' --output text)"
check_empty 'Client VPN CloudWatch log groups' "$log_groups"

if aws iam get-role --role-name openshift-upi-lab-infrastructure --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1; then
  fail 'IAM infrastructure role remains'
else
  pass 'IAM infrastructure role: none'
fi

if aws iam get-instance-profile --instance-profile-name openshift-upi-lab-infrastructure --profile "$AWS_PROFILE_NAME" >/dev/null 2>&1; then
  fail 'IAM instance profile remains'
else
  pass 'IAM instance profile: none'
fi

if aws ec2 describe-key-pairs --key-names openshift-upi-lab-key --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" >/dev/null 2>&1; then
  fail 'EC2 Key Pair remains'
else
  pass 'EC2 Key Pair: none'
fi

acm_certificates="$(aws resourcegroupstaggingapi get-resources \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --resource-type-filters acm:certificate \
  --tag-filters Key=Project,Values=openshift-upi-lab \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)"
check_empty 'Imported Client VPN ACM certificates' "$acm_certificates"

hosted_zone_count="$(aws route53 list-hosted-zones-by-name \
  --dns-name lab.k8study.com \
  --profile "$AWS_PROFILE_NAME" \
  --query 'length(HostedZones[?Name==`lab.k8study.com.` && Config.PrivateZone==`false`])' \
  --output text)"
[[ "$hosted_zone_count" == 1 ]] && pass 'Existing lab.k8study.com Public Hosted Zone is retained' || fail "Expected exactly one retained Public Hosted Zone, found $hosted_zone_count"

printf '\n=== Cleanup Result ===\nFailures: %d\n' "$failures"
((failures == 0)) || exit 1

install -d -m 700 "$(dirname -- "$CLEANUP_MARKER_FILE")"
marker_temp="$(mktemp "$(dirname -- "$CLEANUP_MARKER_FILE")/.cleanup-validated.XXXXXX")"
chmod 600 "$marker_temp"
jq -n \
  --arg account_id "$TF_VAR_expected_account_id" \
  --arg region "$AWS_REGION_NAME" \
  --arg workspace "$LAB_EXPECTED_WORKSPACE" \
  --arg state_lineage "$state_lineage" \
  --argjson state_serial "$state_serial" \
  --arg validated_at "$(date -Iseconds)" \
  '{account_id:$account_id,region:$region,workspace:$workspace,
    state_lineage:$state_lineage,state_serial:$state_serial,managed_resource_count:0,
    validated_at:$validated_at}' >"$marker_temp"
mv -- "$marker_temp" "$CLEANUP_MARKER_FILE"
printf 'Cleanup validation PASSED. No lab resources were found.\n'
printf 'Cleanup validation marker: %s\n' "$CLEANUP_MARKER_FILE"
printf 'Optional local cleanup: bash scripts/35-clean-local-artifacts.sh\n'
