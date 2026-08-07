#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env
reject_example_domain
need aws; need envsubst; need jq
for v in CONTROL_PLANE_INSTANCE_TYPE CONTROL_PLANE_VOLUME_SIZE PULL_SECRET_FILE SSH_PUBLIC_KEY_FILE; do require_var "$v"; done
[[ -r "$PULL_SECRET_FILE" && -r "$SSH_PUBLIC_KEY_FILE" ]] || die "Pull Secret または SSH 公開鍵を読めません"
zone_count="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN" --query "length(HostedZones[?Name=='${BASE_DOMAIN}.'])" --output text)"
[[ "$zone_count" -ge 1 ]] || die "Public Hosted Zone ${BASE_DOMAIN}. が見つかりません。install-configは作成しません"
export PULL_SECRET SSH_PUBLIC_KEY
PULL_SECRET="$(jq -c . "$PULL_SECRET_FILE")"; SSH_PUBLIC_KEY="$(tr -d '\r\n' < "$SSH_PUBLIC_KEY_FILE")"
mkdir -p "$INSTALL_DIR"; umask 077
target="$INSTALL_DIR/install-config.yaml"
[[ ! -e "$target" ]] || die "$target は既に存在します。意図しない上書きを防ぐため停止しました"
envsubst < "$ROOT_DIR/configs/install-config.example.yaml" > "$target"
cp "$target" "$target.backup"
info "$target と秘密情報を含むバックアップを作成しました。Git に追加しないでください"
