#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"
lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

expected_hosts='{"installer":"10.80.40.10","dns-ntp-0":"10.80.40.11","dns-ntp-1":"10.80.50.11","haproxy-0":"10.80.40.21","haproxy-1":"10.80.50.21","proxy-registry":"10.80.40.31","nfs-0":"10.80.40.41"}'
instances_json="$(terraform -chdir="$TERRAFORM_DIR" output -json infrastructure_instances)"

for host in $(jq -r 'keys[]' <<<"$expected_hosts"); do
  expected_ip="$(jq -r --arg host "$host" '.[$host]' <<<"$expected_hosts")"
  instance_id="$(jq -r --arg host "$host" '.[$host].id // empty' <<<"$instances_json")"
  values="$(aws ec2 describe-instances --instance-ids "$instance_id" --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" --query 'Reservations[0].Instances[0].[State.Name,PrivateIpAddress,PublicIpAddress]' --output text)"
  read -r state private_ip public_ip <<<"$values"
  [[ "$state" == "running" ]] && pass "$host is running" || fail "$host state is $state"
  [[ "$private_ip" == "$expected_ip" ]] && pass "$host private IP is $expected_ip" || fail "$host private IP is $private_ip; expected $expected_ip"
  [[ "$public_ip" == "None" ]] && pass "$host has no public IPv4" || fail "$host unexpectedly has public IPv4 $public_ip"
done

ignition_sg_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw ignition_server_security_group_id 2>/dev/null || true)"
installer_id="$(jq -r '.installer.id // empty' <<<"$instances_json")"
installer_sg_ids_json="$(aws ec2 describe-instances \
  --instance-ids "$installer_id" --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output json)"
if [[ "$ignition_sg_id" == sg-* ]] && jq -e --arg security_group_id "$ignition_sg_id" \
  'index($security_group_id) != null' <<<"$installer_sg_ids_json" >/dev/null; then
  pass 'Installer has the dedicated Ignition Server Security Group'
else
  fail 'Installer is missing the dedicated Ignition Server Security Group'
fi

nlb_arn="$(terraform -chdir="$TERRAFORM_DIR" output -json internal_nlb | jq -r '.arn')"
nlb_values="$(aws elbv2 describe-load-balancers --load-balancer-arns "$nlb_arn" --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" --query 'LoadBalancers[0].[State.Code,Scheme,Type]' --output text)"
read -r nlb_state nlb_scheme nlb_type <<<"$nlb_values"
[[ "$nlb_state" == "active" ]] && pass 'Internal NLB is active' || fail "NLB state is $nlb_state"
[[ "$nlb_scheme" == "internal" ]] && pass 'NLB scheme is internal' || fail "NLB scheme is $nlb_scheme"
[[ "$nlb_type" == "network" ]] && pass 'Load balancer type is network' || fail "Load balancer type is $nlb_type"

listener_ports="$(aws elbv2 describe-listeners --load-balancer-arn "$nlb_arn" --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" --query 'sort_by(Listeners,&Port)[].Port' --output text)"
[[ "$listener_ports" == $'80\t443\t6443\t22623' ]] && pass 'NLB listeners are 80, 443, 6443, and 22623' || fail "Unexpected listener ports: $listener_ports"

printf '\n=== Result ===\nFailures: %d\n' "$failures"
((failures == 0)) || exit 1
printf 'Infrastructure validation PASSED.\n'
printf 'Next: continue docs/05-infrastructure-services.md section 6 (Installer SSH).\n'
