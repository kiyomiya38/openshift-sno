#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need aws
infra="${INFRA_ID:-$(jq -r '.infraID // empty' "$INSTALL_DIR/metadata.json" 2>/dev/null || true)}"
[[ -n "$infra" ]] || die "削除前に控えた INFRA_ID を設定してください"
info "名前またはタグに $infra を含む残存候補を読み取り専用で確認します。無関係な資源は削除しないでください"
active_instances="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" \
  'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'length(Reservations[].Instances[])' --output text)"
if [[ "$active_instances" -gt 0 ]]; then
  printf 'WARNING: 対象クラスターのEC2が %s 台残っています。destroy未実行または未完了です。\n' "$active_instances" >&2
fi
info "Tagging API の一覧は、削除済みリソースを一時的に返す場合があります。以下の直接照会結果を優先してください"
aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --tag-filters "Key=kubernetes.io/cluster/${infra}" --query 'ResourceTagMappingList[].ResourceARN' --output table | mask_account
info "課金対象になり得る直接照会（空なら残存なし）"
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" \
  'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}' --output table
aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter \
  "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" \
  --query "NatGateways[?State!='deleted'].{Id:NatGatewayId,State:State}" --output table
aws ec2 describe-addresses --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" --query 'Addresses[].AllocationId' --output table
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?contains(LoadBalancerName, '${infra}')].LoadBalancerArn" --output table
aws ec2 describe-volumes --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" --query 'Volumes[].{Id:VolumeId,State:State}' --output table
aws ec2 describe-network-interfaces --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status}' --output table
aws ec2 describe-vpc-endpoints --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" --query "VpcEndpoints[?State!='deleted'].{Id:VpcEndpointId,State:State}" --output table
aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" --query 'Vpcs[].{Id:VpcId,State:State}' --output table
