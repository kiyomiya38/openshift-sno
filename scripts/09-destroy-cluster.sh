#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need aws; need openshift-install
[[ -s "$INSTALL_DIR/metadata.json" ]] || die "metadata.json がありません。削除対象を安全に特定できません"
account="$(aws sts get-caller-identity --query Account --output text)"
printf 'AWS Account: %s****%s\nAWS Region: %s\nCluster Name: %s\nInstall Directory: %s\n' "${account:0:4}" "${account:8:4}" "$AWS_REGION" "$CLUSTER_NAME" "$INSTALL_DIR"
read -r -p "削除を続行するにはクラスター名 '${CLUSTER_NAME}' を入力してください: " answer
[[ "$answer" == "$CLUSTER_NAME" ]] || die "一致しないため中止しました"
mkdir -p "$ROOT_DIR/logs"; log="$ROOT_DIR/logs/destroy-cluster-$(date +%Y%m%d-%H%M%S).log"
openshift-install destroy cluster --dir "$INSTALL_DIR" --log-level=info 2>&1 | tee "$log"
info "完了後に scripts/10-check-leftover-resources.sh を実行してください"
