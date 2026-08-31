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

cd "$TERRAFORM_DIR"

failures=0

pass() {
  printf 'PASS: %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

printf '=== Terraform state ===\n'
state_list="$(lab_state_list_allow_absent "$TERRAFORM_DIR")" || exit 1
if [[ -z "$state_list" ]]; then
  managed_resource_count=0
  data_source_count=0
else
  managed_resource_count="$(printf '%s' "$state_list" | grep -vc '^data\.' || true)"
  data_source_count="$(printf '%s' "$state_list" | grep -c '^data\.' || true)"
fi
if (( managed_resource_count >= 26 )); then
  pass "Terraform state contains $managed_resource_count managed resources (minimum 26)"
else
  fail "Terraform state must contain at least 26 managed resources, found $managed_resource_count"
fi
(( data_source_count >= 2 )) && pass "Terraform state contains $data_source_count read-only data sources (minimum 2)" || fail "Expected at least 2 data sources, found $data_source_count"

vpc_id="$(terraform output -raw vpc_id)"
nat_gateway_id="$(terraform output -raw nat_gateway_id)"

printf '\n=== VPC ===\n'
vpc_json="$(aws ec2 describe-vpcs \
  --vpc-ids "$vpc_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"

vpc_state="$(jq -r '.Vpcs[0].State' <<<"$vpc_json")"
vpc_cidr="$(jq -r '.Vpcs[0].CidrBlock' <<<"$vpc_json")"
[[ "$vpc_state" == "available" ]] && pass "VPC is available" || fail "VPC state is $vpc_state"
[[ "$vpc_cidr" == "10.80.0.0/16" ]] && pass "VPC CIDR is $vpc_cidr" || fail "Unexpected VPC CIDR: $vpc_cidr"

printf '\n=== Subnets ===\n'
subnets_json="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$vpc_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"

subnet_count="$(jq '.Subnets | length' <<<"$subnets_json")"
public_ip_subnet_count="$(jq '[.Subnets[] | select(.MapPublicIpOnLaunch == true)] | length' <<<"$subnets_json")"
az_count="$(jq '[.Subnets[].AvailabilityZone] | unique | length' <<<"$subnets_json")"

[[ "$subnet_count" == "9" ]] && pass "Nine subnets exist" || fail "Expected 9 subnets, found $subnet_count"
[[ "$public_ip_subnet_count" == "0" ]] && pass "Public IPv4 auto-assignment is disabled on every subnet" || fail "$public_ip_subnet_count subnets enable public IPv4 auto-assignment"
[[ "$az_count" == "3" ]] && pass "Subnets span three availability zones" || fail "Expected 3 availability zones, found $az_count"

jq -r '.Subnets | sort_by(.CidrBlock)[] | [.AvailabilityZone, .CidrBlock, (.MapPublicIpOnLaunch | tostring)] | @tsv' <<<"$subnets_json"

printf '\n=== NAT Gateway ===\n'
nat_json="$(aws ec2 describe-nat-gateways \
  --nat-gateway-ids "$nat_gateway_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"

nat_state="$(jq -r '.NatGateways[0].State' <<<"$nat_json")"
[[ "$nat_state" == "available" ]] && pass "NAT Gateway is available" || fail "NAT Gateway state is $nat_state"

printf '\n=== Internet Gateway and routes ===\n'
igw_count="$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$vpc_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --query 'length(InternetGateways)' \
  --output text)"
[[ "$igw_count" == "1" ]] && pass "One Internet Gateway is attached" || fail "Expected 1 Internet Gateway, found $igw_count"

default_route_count="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$vpc_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json \
  | jq '[.RouteTables[].Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0" and .State == "active")] | length')"
[[ "$default_route_count" == "2" ]] && pass "Public and private active default routes exist" || fail "Expected 2 active default routes, found $default_route_count"

printf '\n=== Result ===\n'
printf 'Failures: %d\n' "$failures"
if (( failures > 0 )); then
  printf 'Network validation FAILED. Do not continue to Client VPN.\n' >&2
  exit 1
fi

printf 'Network validation PASSED.\n'
printf 'Next: bash scripts/04-01-generate-client-vpn-pki.sh\n'
