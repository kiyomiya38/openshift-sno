#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
BASE_DOMAIN="${BASE_DOMAIN:-lab.k8study.com}"
VERIFIED_OPENSHIFT_VERSION='4.21.26'
EXPECTED_OPENSHIFT_VERSION="${EXPECTED_OPENSHIFT_VERSION:-$VERIFIED_OPENSHIFT_VERSION}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/openshift_upi_lab.pub}"
PULL_SECRET_PATH="${PULL_SECRET_PATH:-$HOME/.config/openshift/pull-secret.json}"
PKI_DIRECTORY="${PKI_DIRECTORY:-$HOME/.config/openshift-upi-lab/pki}"
MINIMUM_STANDARD_VCPUS=42
RECOMMENDED_STANDARD_VCPUS=48
VERIFIED_ANSIBLE_CORE_VERSION='2.21.2'

failures=0
warnings=0

pass() {
  printf 'PASS: %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

section() {
  printf '\n=== %s ===\n' "$*"
}

require_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name is installed"
  else
    fail "$command_name is not installed"
  fi
}

section "Local tools"
for command_name in aws terraform ansible oc openshift-install jq git openssl ssh-keygen flock; do
  require_command "$command_name"
done

if (( failures > 0 )); then
  printf '\nPreflight stopped: required local tools are missing.\n' >&2
  exit 1
fi

section "Local tool versions"
aws_cli_version="$(aws --version 2>&1 | sed -nE 's#^aws-cli/([^ ]+).*$#\1#p')"
terraform_version="$(terraform version -json | jq -r '.terraform_version // empty')"
ansible_core_version="$(ansible --version | sed -nE '1s/^ansible \[core ([^]]+)\].*/\1/p')"
jq_version="$(jq --version | sed 's/^jq-//')"
git_version="$(git --version | awk '{print $3}')"
openssl_version="$(openssl version | awk '{print $2}')"

printf 'AWS CLI: %s\nTerraform: %s\nansible-core: %s\njq: %s\ngit: %s\nOpenSSL: %s\n' \
  "${aws_cli_version:-unknown}" "${terraform_version:-unknown}" \
  "${ansible_core_version:-unknown}" "${jq_version:-unknown}" \
  "${git_version:-unknown}" "${openssl_version:-unknown}"

if [[ "$aws_cli_version" =~ ^2\.[0-9]+\.[0-9]+ ]]; then
  pass "AWS CLI v2 is installed ($aws_cli_version)"
else
  fail "AWS CLI v2 is required, found ${aws_cli_version:-unknown}"
fi

if [[ "$terraform_version" =~ ^1\.([0-9]+)\.[0-9]+ ]] \
  && (( BASH_REMATCH[1] >= 8 )); then
  pass "Terraform $terraform_version satisfies >=1.8,<2.0"
else
  fail "Terraform must satisfy >=1.8,<2.0, found ${terraform_version:-unknown}"
fi

if [[ "$ansible_core_version" =~ ^2\.21\.[0-9]+$ ]]; then
  if [[ "$ansible_core_version" == "$VERIFIED_ANSIBLE_CORE_VERSION" ]]; then
    pass "ansible-core is the verified version $ansible_core_version"
  else
    warn "ansible-core $ansible_core_version is supported by this runbook line but differs from verified $VERIFIED_ANSIBLE_CORE_VERSION; rerun the full validation suite"
  fi
else
  fail "ansible-core 2.21.x is required, found ${ansible_core_version:-unknown}"
fi

section "Terraform execution context"
if workspace_name="$(terraform -chdir="$TERRAFORM_DIR" workspace show 2>/dev/null)"; then
  if [[ "$workspace_name" == "$LAB_EXPECTED_WORKSPACE" ]]; then
    pass "Terraform workspace is $workspace_name"
  else
    fail "Terraform workspace must be $LAB_EXPECTED_WORKSPACE, found $workspace_name"
  fi
else
  fail 'Unable to read the Terraform workspace. Run terraform init before preflight.'
fi

if registered_account_id="$(lab_resolve_expected_account_id strict "$TERRAFORM_DIR" '')"; then
  pass "Expected AWS account is independently registered: $registered_account_id"
else
  fail "Register EXPECTED_AWS_ACCOUNT_ID with scripts/00-register-expected-account.sh before continuing"
  registered_account_id=''
fi

[[ "$EXPECTED_OPENSHIFT_VERSION" =~ ^4\.21\.[0-9]+$ ]] || {
  fail "EXPECTED_OPENSHIFT_VERSION must be an OpenShift 4.21 patch release, found $EXPECTED_OPENSHIFT_VERSION"
}
if [[ "$EXPECTED_OPENSHIFT_VERSION" != "$VERIFIED_OPENSHIFT_VERSION" ]]; then
  warn "OpenShift $EXPECTED_OPENSHIFT_VERSION is an explicit override; this runbook was validated with $VERIFIED_OPENSHIFT_VERSION and must be revalidated"
fi

oc_version="$(oc version --client -o json | jq -r '.releaseClientVersion // empty')"
installer_version="$(openshift-install version | awk 'NR == 1 { print $2 }')"

if [[ "$oc_version" == "$EXPECTED_OPENSHIFT_VERSION" ]]; then
  pass "oc version is $oc_version"
else
  fail "oc version must be $EXPECTED_OPENSHIFT_VERSION, found ${oc_version:-unknown}"
fi

if [[ "$installer_version" == "$EXPECTED_OPENSHIFT_VERSION" ]]; then
  pass "openshift-install version is $installer_version"
else
  fail "openshift-install version must be $EXPECTED_OPENSHIFT_VERSION, found ${installer_version:-unknown}"
fi

if [[ "$oc_version" == "$installer_version" ]]; then
  pass "oc and openshift-install versions match"
else
  fail "oc ($oc_version) and openshift-install ($installer_version) do not match"
fi

section "Local secret files"
if [[ -f "$SSH_PUBLIC_KEY_PATH" ]]; then
  pass "SSH public key exists: $SSH_PUBLIC_KEY_PATH"
  ssh-keygen -lf "$SSH_PUBLIC_KEY_PATH"
else
  fail "SSH public key is missing: $SSH_PUBLIC_KEY_PATH"
fi

if [[ -f "$PULL_SECRET_PATH" ]] && jq empty "$PULL_SECRET_PATH" >/dev/null 2>&1; then
  pass "Pull Secret exists and contains valid JSON: $PULL_SECRET_PATH"
else
  fail "Pull Secret is missing or invalid JSON: $PULL_SECRET_PATH"
fi

if [[ -d "$PKI_DIRECTORY" ]]; then
  pki_mode="$(stat -c '%a' "$PKI_DIRECTORY")"
  if [[ "$pki_mode" == "700" ]]; then
    pass "PKI directory permissions are 700"
  else
    fail "PKI directory permissions must be 700, found $pki_mode"
  fi
else
  fail "PKI directory is missing: $PKI_DIRECTORY"
fi

section "AWS identity"
if ! identity_json="$(aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" --output json)"; then
  fail "AWS authentication failed for profile $AWS_PROFILE_NAME"
else
  account_id="$(jq -r '.Account' <<<"$identity_json")"
  principal_arn="$(jq -r '.Arn' <<<"$identity_json")"
  pass "AWS authentication succeeded"
  printf 'Account: %s\nPrincipal: %s\n' "$account_id" "$principal_arn"
  if [[ -n "$registered_account_id" && "$account_id" == "$registered_account_id" ]]; then
    pass 'Authenticated AWS account matches the independently registered account'
  else
    fail 'Authenticated AWS account does not match the independently registered account'
  fi
fi

configured_region="$(aws configure get region --profile "$AWS_PROFILE_NAME" || true)"
if [[ "$configured_region" == "$AWS_REGION_NAME" ]]; then
  pass "AWS region is $configured_region"
else
  fail "AWS region must be $AWS_REGION_NAME, found ${configured_region:-unset}"
fi

section "Route 53"
hosted_zone_json="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$BASE_DOMAIN" \
  --profile "$AWS_PROFILE_NAME" \
  --output json)"

public_zone_count="$(jq --arg name "$BASE_DOMAIN." \
  '[.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false)] | length' \
  <<<"$hosted_zone_json")"

if [[ "$public_zone_count" == "1" ]]; then
  hosted_zone_id="$(jq -r --arg name "$BASE_DOMAIN." \
    '.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false) | .Id' \
    <<<"$hosted_zone_json")"
  pass "Exactly one public hosted zone was found: $BASE_DOMAIN"
  printf 'Hosted Zone ID: %s\n' "$hosted_zone_id"
else
  fail "Expected one public hosted zone for $BASE_DOMAIN, found $public_zone_count"
fi

section "EC2 quota"
if quota_value="$(aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region "$AWS_REGION_NAME" \
  --profile "$AWS_PROFILE_NAME" \
  --query 'Quota.Value' \
  --output text)"; then
  printf 'Standard On-Demand vCPU quota: %s\n' "$quota_value"
  quota_integer="${quota_value%%.*}"
  if (( quota_integer >= RECOMMENDED_STANDARD_VCPUS )); then
    pass "vCPU quota has recommended headroom (${RECOMMENDED_STANDARD_VCPUS}+ vCPUs)"
  elif (( quota_integer >= MINIMUM_STANDARD_VCPUS )); then
    warn "vCPU quota meets the estimated minimum but has little headroom; ${RECOMMENDED_STANDARD_VCPUS}+ is recommended"
  else
    fail "vCPU quota is below the estimated minimum of $MINIMUM_STANDARD_VCPUS; request an increase to at least $RECOMMENDED_STANDARD_VCPUS"
  fi
else
  fail "Could not read the EC2 Standard On-Demand vCPU quota"
fi

section "Instance type offerings"
offerings_json="$(aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=m6i.xlarge,m6i.large,t3.medium,t3.small \
  --region "$AWS_REGION_NAME" \
  --profile "$AWS_PROFILE_NAME" \
  --output json)"

required_offerings=(
  "ap-northeast-3a:m6i.xlarge"
  "ap-northeast-3b:m6i.xlarge"
  "ap-northeast-3c:m6i.xlarge"
  "ap-northeast-3a:m6i.large"
  "ap-northeast-3a:t3.medium"
  "ap-northeast-3a:t3.small"
  "ap-northeast-3b:t3.small"
)

for required in "${required_offerings[@]}"; do
  az="${required%%:*}"
  instance_type="${required##*:}"
  count="$(jq --arg az "$az" --arg instance_type "$instance_type" \
    '[.InstanceTypeOfferings[] | select(.Location == $az and .InstanceType == $instance_type)] | length' \
    <<<"$offerings_json")"
  if [[ "$count" == "1" ]]; then
    pass "$instance_type is offered in $az"
  else
    fail "$instance_type is not offered in $az"
  fi
done

section "Result"
printf 'Failures: %d\nWarnings: %d\n' "$failures" "$warnings"

if (( failures > 0 )); then
  printf 'Preflight FAILED. Do not run terraform apply.\n' >&2
  exit 1
fi

printf 'Preflight PASSED. It is safe to continue to Terraform planning.\n'
