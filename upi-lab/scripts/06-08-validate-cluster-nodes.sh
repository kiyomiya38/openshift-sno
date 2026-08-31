#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

for command_name in aws dig jq terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context
phase6_require_complete_assets

expected_nodes_json='{
  "bootstrap":"10.80.10.30",
  "control-plane-0":"10.80.10.10",
  "control-plane-1":"10.80.20.10",
  "control-plane-2":"10.80.30.10",
  "worker-0":"10.80.10.20",
  "worker-1":"10.80.20.20",
  "worker-2":"10.80.30.20"
}'
nodes_json="$(terraform -chdir="$TERRAFORM_DIR" output -json openshift_instances)"

[[ "$(jq -r 'length' <<<"$nodes_json")" == 7 ]] || phase6_error 'Terraform output does not contain all seven OpenShift nodes.'

mapfile -t instance_ids < <(jq -r '.[].id' <<<"$nodes_json")
aws ec2 wait instance-running \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "${instance_ids[@]}"

instance_json="$(aws ec2 describe-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "${instance_ids[@]}" \
  --query 'Reservations[].Instances[]' --output json)"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

dns_answer=''
query_dns_until_expected() {
  local dns_server="$1"
  local query_kind="$2"
  local query_value="$3"
  local expected_value="$4"
  local attempt

  for attempt in 1 2 3 4 5; do
    if [[ "$query_kind" == A ]]; then
      dns_answer="$(dig +time=2 +tries=1 +short "@$dns_server" "$query_value" A 2>/dev/null || true)"
    else
      dns_answer="$(dig +time=2 +tries=1 +short "@$dns_server" -x "$query_value" 2>/dev/null || true)"
    fi

    [[ "$dns_answer" == "$expected_value" ]] && return 0
    if (( attempt < 5 )); then
      sleep 2
    fi
  done

  return 1
}

while IFS=$'\t' read -r node_name expected_ip; do
  instance_id="$(jq -r --arg node "$node_name" '.[$node].id' <<<"$nodes_json")"
  actual="$(jq -c --arg id "$instance_id" '.[] | select(.InstanceId == $id)' <<<"$instance_json")"
  actual_ip="$(jq -r '.PrivateIpAddress' <<<"$actual")"
  public_ip="$(jq -r '.PublicIpAddress // empty' <<<"$actual")"
  actual_ami="$(jq -r '.ImageId' <<<"$actual")"
  http_tokens="$(jq -r '.MetadataOptions.HttpTokens' <<<"$actual")"

  [[ "$actual_ip" == "$expected_ip" ]] && pass "$node_name uses fixed IP $expected_ip." || fail "$node_name uses $actual_ip instead of $expected_ip."
  [[ -z "$public_ip" ]] && pass "$node_name has no public IPv4 address." || fail "$node_name has unexpected public IPv4 $public_ip."
  [[ "$actual_ami" == "$RHCOS_AMI_ID" ]] && pass "$node_name uses the installer-selected RHCOS AMI." || fail "$node_name uses unexpected AMI $actual_ami."
  [[ "$http_tokens" == required ]] && pass "$node_name requires IMDSv2." || fail "$node_name does not require IMDSv2."

  for dns_server in 10.80.40.11 10.80.50.11; do
    fqdn="${node_name}.ocp.lab.k8study.com."
    if ! query_dns_until_expected "$dns_server" A "${node_name}.ocp.lab.k8study.com" "$expected_ip"; then
      fail "$dns_server returned an unexpected A record for $node_name: ${dns_answer:-<no answer>}"
    fi
    if ! query_dns_until_expected "$dns_server" PTR "$expected_ip" "$fqdn"; then
      fail "$dns_server returned an unexpected PTR record for $node_name: ${dns_answer:-<no answer>}"
    fi
  done
done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"$expected_nodes_json")

printf '\n=== Result ===\nFailures: %d\n' "$failures"
(( failures == 0 )) || exit 1
printf 'OpenShift node infrastructure validation PASSED.\n'
printf 'Next: bash scripts/06-09-wait-for-bootstrap.sh\n'
