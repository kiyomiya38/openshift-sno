#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need aws
infra="${INFRA_ID:-$(jq -r '.infraID // empty' "$INSTALL_DIR/metadata.json" 2>/dev/null || true)}"
[[ -n "$infra" ]] || die "metadata.json から infraID を取得できません"
filter="Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared"
info "infraID=$infra のタグで読み取り専用照会します"
aws ec2 describe-instances --region "$AWS_REGION" --filters "$filter" --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}' --output table
aws ec2 describe-volumes --region "$AWS_REGION" --filters "$filter" --query 'Volumes[].{Id:VolumeId,State:State,GiB:Size}' --output table
aws ec2 describe-vpcs --region "$AWS_REGION" --filters "$filter" --query 'Vpcs[].VpcId' --output table
aws ec2 describe-subnets --region "$AWS_REGION" --filters "$filter" --query 'Subnets[].SubnetId' --output table
aws ec2 describe-security-groups --region "$AWS_REGION" --filters "$filter" --query 'SecurityGroups[].GroupId' --output table
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?contains(LoadBalancerName, '${infra}')].{Name:LoadBalancerName,State:State.Code}" --output table
aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter "$filter" --query 'NatGateways[].{Id:NatGatewayId,State:State}' --output table
aws ec2 describe-addresses --region "$AWS_REGION" --filters "$filter" --query 'Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp}' --output table
aws route53 list-resource-record-sets --hosted-zone-id "$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN" --query "HostedZones[?Name=='${BASE_DOMAIN}.']|[0].Id" --output text)" --query "ResourceRecordSets[?contains(Name, '${CLUSTER_NAME}.${BASE_DOMAIN}')].[Name,Type]" --output table
