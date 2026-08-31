#!/usr/bin/env bash
set -Eeuo pipefail

VERIFIED_OPENSHIFT_VERSION='4.21.26'
INSTALL_DIR="${OPENSHIFT_TOOLS_INSTALL_DIR:-$HOME/.local/bin}"
BASE_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${VERIFIED_OPENSHIFT_VERSION}"
CLIENT_ARCHIVE="openshift-client-linux-${VERIFIED_OPENSHIFT_VERSION}.tar.gz"
INSTALLER_ARCHIVE="openshift-install-linux-${VERIFIED_OPENSHIFT_VERSION}.tar.gz"
CHECKSUM_FILE='sha256sum.txt'
CLIENT_SHA256='07012f7d450384184c87910c81c81fbd4ebb388e2dcb80aa32837bf22af5c4dc'
INSTALLER_SHA256='253294bfcb740e45b32614571045359bab0a9f9448f2064bb8069aeb23577b47'

tool_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in curl tar sha256sum install mktemp awk wc jq; do
  command -v "$command_name" >/dev/null 2>&1 \
    || tool_error "Required command is not installed: $command_name"
done

[[ "$(uname -s)" == 'Linux' ]] \
  || tool_error 'This installer must run on Linux or WSL Ubuntu.'
[[ "$(uname -m)" == 'x86_64' ]] \
  || tool_error "This release requires x86_64, found $(uname -m)."

current_oc_version=''
current_installer_version=''
if command -v oc >/dev/null 2>&1; then
  current_oc_version="$(
    oc version --client -o json 2>/dev/null \
      | jq -r '.releaseClientVersion // empty' || true
  )"
fi
if command -v openshift-install >/dev/null 2>&1; then
  current_installer_version="$(
    openshift-install version 2>/dev/null | awk 'NR == 1 {print $2}' || true
  )"
fi

if [[ "$current_oc_version" == "$VERIFIED_OPENSHIFT_VERSION" &&
      "$current_installer_version" == "$VERIFIED_OPENSHIFT_VERSION" ]]; then
  printf 'OpenShift client and installer %s are already available.\n' \
    "$VERIFIED_OPENSHIFT_VERSION"
  printf 'oc: %s\n' "$(command -v oc)"
  printf 'openshift-install: %s\n' "$(command -v openshift-install)"
  exit 0
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

printf 'Downloading OpenShift %s tools from the official Red Hat mirror.\n' \
  "$VERIFIED_OPENSHIFT_VERSION"
for file_name in "$CLIENT_ARCHIVE" "$INSTALLER_ARCHIVE" "$CHECKSUM_FILE"; do
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    "$BASE_URL/$file_name" \
    --output "$work_dir/$file_name"
done

awk -v client="$CLIENT_ARCHIVE" -v installer="$INSTALLER_ARCHIVE" \
  '$2 == client || $2 == installer' \
  "$work_dir/$CHECKSUM_FILE" >"$work_dir/sha256sum-selected.txt"

checksum_count="$(wc -l <"$work_dir/sha256sum-selected.txt")"
[[ "$checksum_count" -eq 2 ]] \
  || tool_error 'The official checksum file did not contain both expected archives.'

(
  cd "$work_dir"
  sha256sum --check --strict sha256sum-selected.txt
)

printf '%s  %s\n%s  %s\n' \
  "$CLIENT_SHA256" "$CLIENT_ARCHIVE" \
  "$INSTALLER_SHA256" "$INSTALLER_ARCHIVE" \
  >"$work_dir/sha256sum-pinned.txt"
(
  cd "$work_dir"
  sha256sum --check --strict sha256sum-pinned.txt
)

tar -xzf "$work_dir/$CLIENT_ARCHIVE" -C "$work_dir" oc kubectl
tar -xzf "$work_dir/$INSTALLER_ARCHIVE" -C "$work_dir" openshift-install

install -d -m 700 "$INSTALL_DIR"
install -m 0755 \
  "$work_dir/oc" \
  "$work_dir/kubectl" \
  "$work_dir/openshift-install" \
  "$INSTALL_DIR/"

installed_oc_version="$(
  "$INSTALL_DIR/oc" version --client -o json \
    | jq -r '.releaseClientVersion // empty'
)"
installed_installer_version="$(
  "$INSTALL_DIR/openshift-install" version | awk 'NR == 1 {print $2}'
)"

[[ "$installed_oc_version" == "$VERIFIED_OPENSHIFT_VERSION" ]] \
  || tool_error "Installed oc version is $installed_oc_version."
[[ "$installed_installer_version" == "$VERIFIED_OPENSHIFT_VERSION" ]] \
  || tool_error "Installed openshift-install version is $installed_installer_version."

printf '\nOpenShift tool installation PASSED.\n'
printf 'oc: %s\n' "$INSTALL_DIR/oc"
printf 'kubectl: %s\n' "$INSTALL_DIR/kubectl"
printf 'openshift-install: %s\n' "$INSTALL_DIR/openshift-install"
printf 'Version: %s\n' "$VERIFIED_OPENSHIFT_VERSION"
printf 'Run: export PATH="%s:$PATH"\n' "$INSTALL_DIR"
printf 'Then run: hash -r\n'
