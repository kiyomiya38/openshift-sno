#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need aws; need jq
aws sts get-caller-identity | jq '{
  Account:(.Account|.[0:4]+"****"+.[8:12]),
  PrincipalType:(.Arn|split(":")[5]|split("/")[0])
}'
aws configure list
aws ec2 describe-regions --region "$AWS_REGION" --query 'Regions[].RegionName' --output text >/dev/null
info "認証とリージョン API へのアクセスを確認しました"
