#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
EXPECTED_CLIENT_VPN_DNS_SERVERS="${EXPECTED_CLIENT_VPN_DNS_SERVERS:-10.80.0.2}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

cd "$TERRAFORM_DIR"
failures=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

state_list="$(terraform state list)"
managed_count="$(grep -vc '^data\.' <<<"$state_list" || true)"
if (( managed_count >= 33 )); then
  pass "Terraform state contains $managed_count managed resources (minimum 33)"
else
  fail "Expected at least 33 managed resources, found $managed_count"
fi

endpoint_id="$(terraform output -raw client_vpn_endpoint_id)"

endpoint_json="$(aws ec2 describe-client-vpn-endpoints \
  --client-vpn-endpoint-ids "$endpoint_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"

endpoint_status="$(jq -r '.ClientVpnEndpoints[0].Status.Code' <<<"$endpoint_json")"
client_cidr="$(jq -r '.ClientVpnEndpoints[0].ClientCidrBlock' <<<"$endpoint_json")"
split_tunnel="$(jq -r '.ClientVpnEndpoints[0].SplitTunnel' <<<"$endpoint_json")"
actual_dns_servers="$(jq -r '.ClientVpnEndpoints[0].DnsServers | sort | join(",")' <<<"$endpoint_json")"
expected_dns_servers="$(tr -d '[:space:]' <<<"$EXPECTED_CLIENT_VPN_DNS_SERVERS")"

[[ "$endpoint_status" == "available" ]] && pass "Client VPN endpoint is available" || fail "Endpoint status is $endpoint_status"
[[ "$client_cidr" == "10.81.0.0/22" ]] && pass "Client CIDR is $client_cidr" || fail "Unexpected client CIDR: $client_cidr"
[[ "$split_tunnel" == "true" ]] && pass "Split tunnel is enabled" || fail "Split tunnel is not enabled"
[[ "$actual_dns_servers" == "$expected_dns_servers" ]] && pass "Client VPN DNS servers are $actual_dns_servers" || fail "Expected DNS servers $expected_dns_servers, found $actual_dns_servers"

association_json="$(aws ec2 describe-client-vpn-target-networks \
  --client-vpn-endpoint-id "$endpoint_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"
association_count="$(jq '[.ClientVpnTargetNetworks[] | select(.Status.Code == "associated")] | length' <<<"$association_json")"
expected_association_subnets="$(terraform output -json infra_subnet_ids |
  jq -c '[.["infra-a"], .["infra-b"]] | sort')"
actual_association_subnets="$(jq -c '[.ClientVpnTargetNetworks[] |
  select(.Status.Code == "associated") | .TargetNetworkId] | sort' <<<"$association_json")"
[[ "$association_count" == 2 ]] \
  && pass 'Two target networks are associated in separate availability zones' \
  || fail "Expected 2 associated target networks, found $association_count"
[[ "$actual_association_subnets" == "$expected_association_subnets" ]] \
  && pass 'Client VPN is associated with infra-a and infra-b' \
  || fail "Unexpected Client VPN target subnets: $actual_association_subnets"

authorization_json="$(aws ec2 describe-client-vpn-authorization-rules \
  --client-vpn-endpoint-id "$endpoint_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"
authorization_count="$(jq '[.AuthorizationRules[] | select(.DestinationCidr == "10.80.0.0/16" and .Status.Code == "active")] | length' <<<"$authorization_json")"
[[ "$authorization_count" == "1" ]] && pass "VPC authorization rule is active" || fail "VPC authorization rule is not active"

routes_json="$(aws ec2 describe-client-vpn-routes \
  --client-vpn-endpoint-id "$endpoint_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --output json)"
route_count="$(jq '[.Routes[] | select(.DestinationCidr == "10.80.0.0/16" and .Status.Code == "active")] | length' <<<"$routes_json")"
route_subnets="$(jq -c '[.Routes[] |
  select(.DestinationCidr == "10.80.0.0/16" and .Status.Code == "active") |
  .TargetSubnet] | sort' <<<"$routes_json")"
[[ "$route_count" == 2 ]] \
  && pass 'Two automatically created VPC routes are active' \
  || fail "Expected 2 active VPC routes, found $route_count"
[[ "$route_subnets" == "$expected_association_subnets" ]] \
  && pass 'Active Client VPN routes target infra-a and infra-b' \
  || fail "Unexpected Client VPN route subnets: $route_subnets"

printf '\n=== Result ===\nFailures: %d\n' "$failures"
if (( failures > 0 )); then
  printf 'Client VPN validation FAILED. Review the failed checks before continuing.\n' >&2
  exit 1
fi
printf 'Client VPN validation PASSED.\n'
