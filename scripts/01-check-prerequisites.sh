#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env
reject_example_domain

[[ "$(uname -s)" == Linux ]] || die "WSL2/Ubuntu など Linux の Bash で実行してください"
arch="$(uname -m)"; [[ "$arch" == x86_64 ]] || die "対象は x86_64 です（検出: $arch）"
for c in aws openshift-install oc kubectl jq curl tar git openssl dig envsubst; do need "$c"; done
aws sts get-caller-identity --output json | jq '{
  Account:(.Account|.[0:4]+"****"+.[8:12]),
  PrincipalType:(.Arn|split(":")[5]|split("/")[0])
}'
configured_region="$(aws configure get region || true)"
[[ "${configured_region:-$AWS_REGION}" == "$AWS_REGION" ]] || die "AWS CLI の既定リージョンが $AWS_REGION ではありません"
aws ec2 describe-regions --region-names "$AWS_REGION" --query 'Regions[0].RegionName' --output text >/dev/null
hosted_zone_id="$(get_public_hosted_zone_id)"
info "Public Hosted Zone: ${BASE_DOMAIN}. (${hosted_zone_id})"
require_var CONTROL_PLANE_INSTANCE_TYPE; require_var CONTROL_PLANE_VOLUME_SIZE
[[ "$CONTROL_PLANE_VOLUME_SIZE" -ge 120 ]] || die "ルートボリュームは公式最小 120 GiB 以上が必要です"
aws ec2 describe-instance-type-offerings --region "$AWS_REGION" --location-type region \
  --filters "Name=instance-type,Values=${CONTROL_PLANE_INSTANCE_TYPE}" \
  --query 'InstanceTypeOfferings[0].InstanceType' --output text | grep -qx "$CONTROL_PLANE_INSTANCE_TYPE" || \
  die "$CONTROL_PLANE_INSTANCE_TYPE は $AWS_REGION で提供されていません"
aws ec2 describe-instance-types --region "$AWS_REGION" --instance-types "$CONTROL_PLANE_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].{vCPU:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB}' --output table
for f in "$PULL_SECRET_FILE" "$SSH_PUBLIC_KEY_FILE"; do [[ -r "$f" ]] || die "読み取り可能なファイルがありません: $f"; done
jq -e 'type=="object" and length>0' "$PULL_SECRET_FILE" >/dev/null || die "Pull Secret が JSON object ではありません"
grep -Eq '^ssh-(rsa|ed25519|ecdsa)' "$SSH_PUBLIC_KEY_FILE" || die "SSH 公開鍵の形式を確認してください"
mkdir -p "$INSTALL_DIR"
free_kib="$(df -Pk "$INSTALL_DIR" | awk 'NR==2 {print $4}')"; [[ "$free_kib" -ge 5242880 ]] || die "作業領域に 5 GiB 以上の空きが必要です"
curl -fsS https://checkip.amazonaws.com | sed 's/^/Public IP (参考): /'
info "基本前提を確認しました。サービスクォータは scripts/03-check-service-quotas.sh も確認してください"
