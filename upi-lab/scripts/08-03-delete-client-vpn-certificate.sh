#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
ARN_FILE="${ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

[[ -s "$ARN_FILE" ]] || {
  printf 'No ACM ARN file remains. Nothing to delete.\n'
  exit 0
}

certificate_arn="$(<"$ARN_FILE")"
lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id legacy "$TERRAFORM_DIR" "$ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"
lab_assert_no_recovery_or_active_test
account_id="$TF_VAR_expected_account_id"

remaining_managed="$(lab_managed_state_count_allow_absent "$TERRAFORM_DIR")"
[[ "$remaining_managed" == 0 ]] || {
  printf 'ERROR: Terraform still manages %s resources. Apply the destroy Plan first.\n' "$remaining_managed" >&2
  exit 1
}
[[ "$certificate_arn" =~ ^arn:aws:acm:${AWS_REGION_NAME}:${account_id}:certificate/[0-9a-f-]+$ ]] || {
  printf 'ERROR: ARN file does not identify an ACM certificate in the active account and region.\n' >&2
  exit 1
}

describe_error_file="$(mktemp)"
if ! certificate_json="$(aws acm describe-certificate \
  --certificate-arn "$certificate_arn" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --query Certificate \
  --output json 2>"$describe_error_file")"; then
  if grep -q 'ResourceNotFoundException' "$describe_error_file"; then
    rm -- "$ARN_FILE" "$describe_error_file"
    printf 'The ACM certificate no longer exists. Removed the stale local ARN file.\n'
    exit 0
  fi
  cat "$describe_error_file" >&2
  rm -- "$describe_error_file"
  printf 'ERROR: Could not verify whether the ACM certificate exists. The ARN file was retained.\n' >&2
  exit 1
fi
rm -- "$describe_error_file"

project_tag="$(aws acm list-tags-for-certificate \
  --certificate-arn "$certificate_arn" \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --query 'Tags[?Key==`Project`].Value | [0]' --output text)"
[[ "$project_tag" == openshift-upi-lab ]] || {
  printf 'ERROR: Certificate does not have Project=openshift-upi-lab. Refusing deletion.\n' >&2
  exit 1
}

in_use_count="$(jq -r '.InUseBy | length' <<<"$certificate_json")"
[[ "$in_use_count" == 0 ]] || {
  printf 'ERROR: Certificate is still in use. Complete Terraform destroy before deleting it.\n' >&2
  jq -r '.InUseBy[]' <<<"$certificate_json" >&2
  exit 1
}

jq '{Subject,Status,InUseBy}' <<<"$certificate_json"

read -r -p 'Type DELETE-LAB-CERTIFICATE to continue: ' CONFIRM
if [[ "$CONFIRM" == 'DELETE-LAB-CERTIFICATE' ]]; then
  aws acm delete-certificate \
    --certificate-arn "$certificate_arn" \
    --profile "$AWS_PROFILE_NAME" \
    --region "$AWS_REGION_NAME"
  rm -- "$ARN_FILE"
  printf 'Deleted the lab ACM certificate and its stale local ARN file. PKI keys were retained.\n'
else
  printf 'Certificate deletion cancelled.\n'
fi
