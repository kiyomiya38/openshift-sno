#!/usr/bin/env bash
set -Eeuo pipefail

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
PKI_DIRECTORY="${PKI_DIRECTORY:-$HOME/.config/openshift-upi-lab/pki}"
CLIENT_NAME_FILE="${CLIENT_NAME_FILE:-$PKI_DIRECTORY/client-name}"
CONFIG_DIRECTORY="${CONFIG_DIRECTORY:-$HOME/.config/openshift-upi-lab/client-config}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd -- "$SCRIPT_DIR/../terraform" && pwd)"
OUTPUT_FILE="$CONFIG_DIRECTORY/openshift-upi-lab.ovpn"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

lab_assert_default_workspace "$TERRAFORM_DIR"
lab_export_expected_account_id strict "$TERRAFORM_DIR" ''
lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME"

if [[ -n ${CLIENT_NAME:-} ]]; then
  selected_client_name="$CLIENT_NAME"
elif [[ -s "$CLIENT_NAME_FILE" ]]; then
  selected_client_name="$(tr -d '[:space:]' <"$CLIENT_NAME_FILE")"
else
  shopt -s nullglob
  legacy_certificates=("$PKI_DIRECTORY"/client-*.crt)
  shopt -u nullglob
  [[ ${#legacy_certificates[@]} == 1 ]] || {
    printf 'ERROR: CLIENT_NAME is not set and %s does not identify exactly one client certificate.\n' "$CLIENT_NAME_FILE" >&2
    exit 1
  }
  selected_client_name="$(basename -- "${legacy_certificates[0]}" .crt)"
  selected_client_name="${selected_client_name#client-}"
fi
[[ "$selected_client_name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || {
  printf 'ERROR: Resolved CLIENT_NAME is invalid: %s\n' "$selected_client_name" >&2
  exit 1
}
CLIENT_NAME="$selected_client_name"

client_certificate="$PKI_DIRECTORY/client-$CLIENT_NAME.crt"
client_key="$PKI_DIRECTORY/client-$CLIENT_NAME.key"

for file_path in "$client_certificate" "$client_key"; do
  if [[ ! -f "$file_path" ]]; then
    printf 'ERROR: Missing %s\n' "$file_path" >&2
    exit 1
  fi
done

if [[ ! -s "$CLIENT_NAME_FILE" ]]; then
  umask 077
  printf '%s\n' "$CLIENT_NAME" >"$CLIENT_NAME_FILE"
  chmod 600 "$CLIENT_NAME_FILE"
fi

client_vpn_endpoint_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw client_vpn_endpoint_id)"

install -d -m 700 "$CONFIG_DIRECTORY"
umask 077

aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id "$client_vpn_endpoint_id" \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --query ClientConfiguration \
  --output text >"$OUTPUT_FILE"

# AWS may export an unquoted verify-x509-name value when the CA common name
# contains spaces. OpenVPN then treats the extra words as invalid parameters.
awk '
  /^verify-x509-name / {
    value = substr($0, length("verify-x509-name ") + 1)
    sub(/\r$/, "", value)
    if (sub(/ name$/, "", value)) {
      gsub(/\\/, "\\\\", value)
      gsub(/"/, "\\\"", value)
      printf "verify-x509-name \"%s\" name\n", value
      next
    }
  }
  { print }
' "$OUTPUT_FILE" >"$OUTPUT_FILE.tmp"
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

{
  printf '\n<cert>\n'
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$client_certificate"
  printf '</cert>\n<key>\n'
  cat "$client_key"
  printf '</key>\n'
} >>"$OUTPUT_FILE"

chmod 600 "$OUTPUT_FILE"

printf 'Client configuration created: %s\n' "$OUTPUT_FILE"
printf 'Windows path: '
wslpath -w "$OUTPUT_FILE"
printf 'This file contains a private key. Do not commit or share it.\n'
