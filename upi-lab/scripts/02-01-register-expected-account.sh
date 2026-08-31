#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

for command_name in aws install; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: Required command is not installed: %s\n' "$command_name" >&2
    exit 1
  }
done

if [[ -z ${EXPECTED_AWS_ACCOUNT_ID:-} ]]; then
  printf 'Enter the AWS Account ID approved for this lab.\n'
  printf 'Use a value verified independently of the active AWS CLI session.\n'
  if ! read -r -p 'Approved 12-digit AWS Account ID (not an AKIA/ASIA access key): ' \
    EXPECTED_AWS_ACCOUNT_ID; then
    printf 'ERROR: Unable to read the approved AWS Account ID.\n' >&2
    exit 1
  fi
fi
if [[ "$EXPECTED_AWS_ACCOUNT_ID" =~ ^(AKIA|ASIA) ]]; then
  printf 'ERROR: EXPECTED_AWS_ACCOUNT_ID contains an AWS Access Key ID, not an AWS Account ID.\n' >&2
  printf 'Enter the independently approved 12-digit account number. Never enter a Secret Access Key here.\n' >&2
  exit 1
fi
lab_validate_account_id "$EXPECTED_AWS_ACCOUNT_ID" || {
  printf 'ERROR: EXPECTED_AWS_ACCOUNT_ID must contain exactly 12 digits, for example 123456789012.\n' >&2
  printf 'Do not enter an Access Key ID beginning with AKIA or ASIA.\n' >&2
  exit 1
}

lab_assert_aws_identity "$EXPECTED_AWS_ACCOUNT_ID" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

printf 'AWS profile: %s\n' "$AWS_PROFILE_NAME"
printf 'AWS region: %s\n' "$AWS_REGION_NAME"
printf 'Account to register: %s\n' "$EXPECTED_AWS_ACCOUNT_ID"
printf 'Destination: %s\n' "$LAB_EXPECTED_ACCOUNT_FILE"
read -r -p "Type REGISTER-${EXPECTED_AWS_ACCOUNT_ID} to continue: " CONFIRM
if [[ "$CONFIRM" != "REGISTER-${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  printf 'Registration cancelled.\n'
  exit 0
fi

install -d -m 700 "$(dirname -- "$LAB_EXPECTED_ACCOUNT_FILE")"
umask 077
printf '%s\n' "$EXPECTED_AWS_ACCOUNT_ID" >"$LAB_EXPECTED_ACCOUNT_FILE"
chmod 600 "$LAB_EXPECTED_ACCOUNT_FILE"
printf 'Registered the expected AWS account without deriving it from the active session.\n'
printf 'Future Plan, Apply, validation, and destroy scripts will reuse this registered guard.\n'
printf 'Next: continue docs/02-prerequisites.md from section 3 (Terraform).\n'
printf 'Run scripts/02-03-preflight.sh only after all prerequisite sections are complete.\n'
