#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"
PKI_DIRECTORY="${PKI_DIRECTORY:-$HOME/.config/openshift-upi-lab/pki}"
ARN_FILE="$PKI_DIRECTORY/acm-server-certificate-arn.txt"

for file_path in ca.crt server.crt server.key; do
  if [[ ! -f "$PKI_DIRECTORY/$file_path" ]]; then
    printf 'ERROR: Missing %s\n' "$PKI_DIRECTORY/$file_path" >&2
    exit 1
  fi
done

lab_export_expected_account_id strict '' "$ARN_FILE"
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

if [[ -f "$ARN_FILE" ]]; then
  existing_arn="$(<"$ARN_FILE")"
  if aws acm describe-certificate \
    --certificate-arn "$existing_arn" \
    --profile "$AWS_PROFILE_NAME" \
    --region "$AWS_REGION_NAME" >/dev/null 2>&1; then
    printf 'Existing ACM certificate is still available. No new certificate was imported.\n'
    printf 'ARN file: %s\n' "$ARN_FILE"
    exit 0
  fi
  printf 'ERROR: ARN file exists but its ACM certificate cannot be read. Investigate before replacing it.\n' >&2
  exit 1
fi

certificate_arn="$(aws acm import-certificate \
  --certificate "fileb://$PKI_DIRECTORY/server.crt" \
  --private-key "fileb://$PKI_DIRECTORY/server.key" \
  --certificate-chain "fileb://$PKI_DIRECTORY/ca.crt" \
  --tags Key=Project,Value=openshift-upi-lab Key=ManagedBy,Value=Script \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --query CertificateArn \
  --output text)"
[[ "$certificate_arn" =~ ^arn:aws:acm:${AWS_REGION_NAME}:${TF_VAR_expected_account_id}:certificate/[0-9a-f-]+$ ]] || {
  printf 'ERROR: ACM returned a certificate ARN outside the registered account or fixed region.\n' >&2
  exit 1
}

umask 077
printf '%s\n' "$certificate_arn" >"$ARN_FILE"
chmod 600 "$ARN_FILE"

aws acm describe-certificate \
  --certificate-arn "$certificate_arn" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --query 'Certificate.{Status:Status,Type:Type,DomainName:DomainName,NotAfter:NotAfter}' \
  --output table

printf 'ACM import completed. ARN was saved to %s\n' "$ARN_FILE"
