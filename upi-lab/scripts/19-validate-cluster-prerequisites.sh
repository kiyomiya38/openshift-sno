#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

for command_name in ansible aws dig jq sha512sum terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context
phase6_require_complete_assets
phase6_assert_assets_fresh

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

dhcp_options_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw cluster_dhcp_options_id 2>/dev/null || true)"
vpc_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw vpc_id)"

[[ "$dhcp_options_id" == dopt-* ]] && pass "Cluster DHCP options exist: $dhcp_options_id" || fail 'Cluster DHCP options output is missing.'

associated_dhcp="$(aws ec2 describe-vpcs \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --vpc-ids "$vpc_id" --query 'Vpcs[0].DhcpOptionsId' --output text)"
[[ "$associated_dhcp" == "$dhcp_options_id" ]] && pass 'The custom DHCP options are associated with the lab VPC.' \
  || fail "VPC uses $associated_dhcp instead of $dhcp_options_id."

ignition_sg_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw ignition_server_security_group_id 2>/dev/null || true)"
installer_id="$(terraform -chdir="$TERRAFORM_DIR" output -json infrastructure_instances | jq -er '.installer.id')"
installer_sg_ids_json="$(aws ec2 describe-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$installer_id" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output json)"
if [[ "$ignition_sg_id" == sg-* ]] && jq -e --arg security_group_id "$ignition_sg_id" \
  'index($security_group_id) != null' <<<"$installer_sg_ids_json" >/dev/null; then
  pass 'Installer has the dedicated Ignition Server Security Group.'
else
  fail 'Installer is missing the dedicated Ignition Server Security Group.'
fi

dhcp_json="$(aws ec2 describe-dhcp-options \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --dhcp-options-ids "$dhcp_options_id" --output json)"
jq -e '[.DhcpOptions[0].DhcpConfigurations[] | select(.Key == "domain-name-servers").Values[].Value] | sort == ["10.80.40.11","10.80.50.11"]' \
  <<<"$dhcp_json" >/dev/null && pass 'DHCP DNS servers are the two BIND hosts.' || fail 'DHCP DNS server values are incorrect.'
jq -e '[.DhcpOptions[0].DhcpConfigurations[] | select(.Key == "ntp-servers").Values[].Value] | sort == ["10.80.40.11","10.80.50.11"]' \
  <<<"$dhcp_json" >/dev/null && pass 'DHCP NTP servers are the two chrony hosts.' || fail 'DHCP NTP server values are incorrect.'

for dns_server in 10.80.40.11 10.80.50.11; do
  [[ "$(dig +short "@$dns_server" api-int.ocp.lab.k8study.com A | sort | paste -sd, -)" == '10.80.10.5,10.80.20.5,10.80.30.5' ]] \
    && pass "$dns_server resolves api-int to all NLB addresses." \
    || fail "$dns_server returned unexpected api-int addresses."
  [[ "$(dig +short "@$dns_server" test.apps.ocp.lab.k8study.com A | sort | paste -sd, -)" == '10.80.10.5,10.80.20.5,10.80.30.5' ]] \
    && pass "$dns_server resolves the apps wildcard." \
    || fail "$dns_server returned unexpected apps wildcard addresses."
done

(
  cd "$INSTALL_DIR"
  sha512sum -c SHA512SUMS >/dev/null
) && pass 'Local Ignition files match SHA512SUMS.' || fail 'Local Ignition checksum verification failed.'

for role in bootstrap master worker; do
  if ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible installer \
    -i "$ANSIBLE_DIR/inventory/hosts.yml" \
    -m ansible.builtin.uri \
    -a "url=$IGNITION_BASE_URL/$role.ign status_code=200 return_content=false" >/dev/null; then
    pass "Installer serves $role.ign over private HTTP."
  else
    fail "Installer did not serve $role.ign successfully."
  fi
done

node_count="$(terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null | grep -c '^aws_instance\.openshift\[' || true)"
[[ "$node_count" == 0 ]] && pass 'No OpenShift EC2 nodes exist before the node Plan.' || fail "$node_count OpenShift EC2 nodes already exist."

printf '\n=== Result ===\nFailures: %d\n' "$failures"
(( failures == 0 )) || exit 1
printf 'Cluster prerequisite validation PASSED.\n'
printf 'Next: bash scripts/20-plan-cluster-nodes.sh\n'
