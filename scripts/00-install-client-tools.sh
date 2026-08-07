#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR

[[ "$(uname -s)" == Linux ]] || {
  echo "ERROR: Git Bash ではなく、Windows Terminal から Ubuntu (WSL2) を開いて実行してください" >&2
  exit 1
}

if grep -qi microsoft /proc/version; then
  echo "INFO: WSL2 上の Linux を検出しました"
else
  echo "INFO: Linux を検出しました（WSL2 以外では本教材のパスを読み替えてください）"
fi

arch="$(uname -m)"
[[ "$arch" == x86_64 ]] || {
  echo "ERROR: この教材の対象は x86_64 です（検出: $arch）" >&2
  exit 1
}

ocp_channel="${OPENSHIFT_VERSION:-latest-4.21}"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

echo "INFO: Ubuntu パッケージを導入します"
sudo apt-get update
sudo apt-get install -y curl unzip jq tar git openssl dnsutils gettext-base ca-certificates shellcheck

echo "INFO: AWS CLI v2 (Linux x86_64) を導入または更新します"
curl --fail --location --proto '=https' --tlsv1.2 \
  'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' \
  --output "$work_dir/awscliv2.zip"
unzip -q "$work_dir/awscliv2.zip" -d "$work_dir"
sudo "$work_dir/aws/install" --update

echo "INFO: OpenShift ${ocp_channel} の Linux client と installer を導入します"
base_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ocp_channel}"
curl --fail --location --proto '=https' --tlsv1.2 \
  "$base_url/openshift-client-linux.tar.gz" \
  --output "$work_dir/openshift-client-linux.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 \
  "$base_url/openshift-install-linux.tar.gz" \
  --output "$work_dir/openshift-install-linux.tar.gz"
tar -xzf "$work_dir/openshift-client-linux.tar.gz" -C "$work_dir" oc kubectl
tar -xzf "$work_dir/openshift-install-linux.tar.gz" -C "$work_dir" openshift-install
sudo install -m 0755 "$work_dir/oc" "$work_dir/kubectl" "$work_dir/openshift-install" /usr/local/bin/

echo "INFO: 導入結果"
uname -m
aws --version
openshift-install version
oc version --client
kubectl version --client
jq --version
git --version

