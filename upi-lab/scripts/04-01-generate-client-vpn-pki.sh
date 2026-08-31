#!/usr/bin/env bash
set -Eeuo pipefail

EASYRSA_VERSION="${EASYRSA_VERSION:-3.2.6}"
EASYRSA_COMMIT='0d746eec3f06210ae1710d17b9c8d38428058e19'
PKI_DIRECTORY="${PKI_DIRECTORY:-$HOME/.config/openshift-upi-lab/pki}"
EASYRSA_CACHE_DIRECTORY="${EASYRSA_CACHE_DIRECTORY:-$HOME/.cache/openshift-upi-lab/easy-rsa-$EASYRSA_VERSION}"
CLIENT_NAME_FILE="${CLIENT_NAME_FILE:-$PKI_DIRECTORY/client-name}"

for command_name in git install openssl sha256sum stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: Required command is not installed: %s\n' "$command_name" >&2
    exit 1
  }
done

if [[ -n ${CLIENT_NAME:-} ]]; then
  selected_client_name="$CLIENT_NAME"
elif [[ -s "$CLIENT_NAME_FILE" ]]; then
  selected_client_name="$(tr -d '[:space:]' <"$CLIENT_NAME_FILE")"
else
  legacy_client_names=()
  if [[ -d "$PKI_DIRECTORY" ]]; then
    shopt -s nullglob
    for client_certificate in "$PKI_DIRECTORY"/client-*.crt; do
      legacy_name="${client_certificate##*/client-}"
      legacy_name="${legacy_name%.crt}"
      if [[ -s "$PKI_DIRECTORY/client-${legacy_name}.key" ]]; then
        legacy_client_names+=("$legacy_name")
      fi
    done
    shopt -u nullglob
  fi
  case "${#legacy_client_names[@]}" in
    0)
      selected_client_name='workstation-01'
      ;;
    1)
      selected_client_name="${legacy_client_names[0]}"
      printf 'Detected one legacy Client VPN certificate pair: client-%s\n' \
        "$selected_client_name"
      ;;
    *)
      printf 'ERROR: Multiple legacy Client VPN certificate pairs exist.\n' >&2
      printf 'Set CLIENT_NAME to the approved non-personal client name and rerun.\n' >&2
      exit 1
      ;;
  esac
fi
[[ "$selected_client_name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || {
  printf 'ERROR: CLIENT_NAME must use 1-63 lowercase letters, digits, or hyphens.\n' >&2
  exit 1
}
CLIENT_NAME="$selected_client_name"

required_files=(ca.crt server.crt server.key "client-$CLIENT_NAME.crt" "client-$CLIENT_NAME.key")
existing_required_count=0
for file_name in "${required_files[@]}"; do
  if [[ -s "$PKI_DIRECTORY/$file_name" ]]; then
    existing_required_count=$((existing_required_count + 1))
  fi
done

certificate_public_key_hash() {
  openssl x509 -in "$1" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | sha256sum \
    | awk '{print $1}'
}

private_public_key_hash() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null \
    | sha256sum \
    | awk '{print $1}'
}

if ((existing_required_count == ${#required_files[@]})); then
  openssl verify -CAfile "$PKI_DIRECTORY/ca.crt" \
    "$PKI_DIRECTORY/server.crt" \
    "$PKI_DIRECTORY/client-$CLIENT_NAME.crt"
  openssl x509 -checkend 86400 -noout -in "$PKI_DIRECTORY/server.crt" \
    || {
      printf 'ERROR: Existing Server certificate expires within 24 hours.\n' >&2
      exit 1
    }
  openssl x509 -checkend 86400 -noout -in "$PKI_DIRECTORY/client-$CLIENT_NAME.crt" \
    || {
      printf 'ERROR: Existing Client certificate expires within 24 hours.\n' >&2
      exit 1
    }
  [[ "$(certificate_public_key_hash "$PKI_DIRECTORY/server.crt")" == \
      "$(private_public_key_hash "$PKI_DIRECTORY/server.key")" ]] || {
    printf 'ERROR: Existing Server certificate and private key do not match.\n' >&2
    exit 1
  }
  [[ "$(certificate_public_key_hash "$PKI_DIRECTORY/client-$CLIENT_NAME.crt")" == \
      "$(private_public_key_hash "$PKI_DIRECTORY/client-$CLIENT_NAME.key")" ]] || {
    printf 'ERROR: Existing Client certificate and private key do not match.\n' >&2
    exit 1
  }
  chmod 600 \
    "$PKI_DIRECTORY/server.key" \
    "$PKI_DIRECTORY/client-$CLIENT_NAME.key"
  umask 077
  printf '%s\n' "$CLIENT_NAME" >"$CLIENT_NAME_FILE"
  chmod 600 "$CLIENT_NAME_FILE"
  printf '\nExisting PKI validation PASSED. No certificate or private key was regenerated.\n'
  printf 'Persisted Client VPN certificate name: %s (%s)\n' \
    "$CLIENT_NAME" "$CLIENT_NAME_FILE"
  printf 'Next: bash scripts/04-02-import-client-vpn-certificate.sh\n'
  exit 0
fi

if ((existing_required_count > 0)) \
  || [[ -e "$CLIENT_NAME_FILE" || -d "$PKI_DIRECTORY/easyrsa-pki" ]]; then
  printf 'ERROR: Partial or inconsistent PKI exists in %s.\n' "$PKI_DIRECTORY" >&2
  printf 'Existing PKI is not overwritten. Restore the missing files or rotate the PKI deliberately.\n' >&2
  exit 1
fi

install -d -m 700 "$PKI_DIRECTORY"
install -d -m 700 "$(dirname "$EASYRSA_CACHE_DIRECTORY")"

if [[ ! -x "$EASYRSA_CACHE_DIRECTORY/easyrsa" ]]; then
  git clone --no-checkout --filter=blob:none \
    https://github.com/OpenVPN/easy-rsa.git "$EASYRSA_CACHE_DIRECTORY"
  git -C "$EASYRSA_CACHE_DIRECTORY" fetch --depth 1 origin "$EASYRSA_COMMIT"
  git -C "$EASYRSA_CACHE_DIRECTORY" checkout --detach "$EASYRSA_COMMIT"
fi

actual_easyrsa_commit="$(git -C "$EASYRSA_CACHE_DIRECTORY" rev-parse HEAD)"
[[ "$actual_easyrsa_commit" == "$EASYRSA_COMMIT" ]] || {
  printf 'ERROR: Easy-RSA cache is not the approved v%s commit.\n' "$EASYRSA_VERSION" >&2
  printf 'Expected: %s\nActual:   %s\n' "$EASYRSA_COMMIT" "$actual_easyrsa_commit" >&2
  exit 1
}

export EASYRSA_BATCH=1
export EASYRSA_PKI="$PKI_DIRECTORY/easyrsa-pki"
export EASYRSA_REQ_CN="OpenShift UPI Lab Client VPN CA"

cd "$EASYRSA_CACHE_DIRECTORY/easyrsa3"

./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa --san=DNS:server build-server-full server nopass
./easyrsa build-client-full "client-$CLIENT_NAME" nopass

install -m 644 "$EASYRSA_PKI/ca.crt" "$PKI_DIRECTORY/ca.crt"
install -m 644 "$EASYRSA_PKI/issued/server.crt" "$PKI_DIRECTORY/server.crt"
install -m 600 "$EASYRSA_PKI/private/server.key" "$PKI_DIRECTORY/server.key"
install -m 644 "$EASYRSA_PKI/issued/client-$CLIENT_NAME.crt" "$PKI_DIRECTORY/client-$CLIENT_NAME.crt"
install -m 600 "$EASYRSA_PKI/private/client-$CLIENT_NAME.key" "$PKI_DIRECTORY/client-$CLIENT_NAME.key"
printf '%s\n' "$CLIENT_NAME" >"$CLIENT_NAME_FILE"
chmod 600 "$CLIENT_NAME_FILE"

openssl verify -CAfile "$PKI_DIRECTORY/ca.crt" \
  "$PKI_DIRECTORY/server.crt" \
  "$PKI_DIRECTORY/client-$CLIENT_NAME.crt"

printf '\nGenerated files:\n'
find "$PKI_DIRECTORY" -maxdepth 1 -type f -printf '%m %f\n' | sort
printf '\nPKI generation completed. Private keys remain outside the repository.\n'
printf 'Persisted Client VPN certificate name: %s (%s)\n' "$CLIENT_NAME" "$CLIENT_NAME_FILE"
printf 'Next: bash scripts/04-02-import-client-vpn-certificate.sh\n'
