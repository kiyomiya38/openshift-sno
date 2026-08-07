#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need aws
printf '%-14s %-12s %-12s\n' SERVICE QUOTA_CODE VALUE
for item in 'ec2 L-1216C47A' 'vpc L-F678F1CE' 'ec2 L-0263D0A3' 'vpc L-29B6F2EB'; do
  read -r service code <<<"$item"
  value="$(aws service-quotas get-service-quota --region "$AWS_REGION" --service-code "$service" --quota-code "$code" --query 'Quota.Value' --output text 2>/dev/null || echo '要手動確認')"
  printf '%-14s %-12s %-12s\n' "$service" "$code" "$value"
done
info "vCPU・VPC・Elastic IP・NAT Gateway 等は Service Quotas コンソールでも使用量と合わせて確認してください"
