#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/configs/environment}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "必須コマンド '$1' が見つかりません"; }
require_var() { [[ -n "${!1:-}" ]] || die "環境変数 $1 を設定してください"; }
reject_example_domain() {
  case "${BASE_DOMAIN:-}" in
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|example.jp|*.example.jp)
      die "BASE_DOMAIN=${BASE_DOMAIN} は説明用の予約ドメインです。所有し、Route 53 Public Hosted Zoneを作成済みの実ドメインへ変更してください"
      ;;
  esac
}
get_public_hosted_zone_id() {
  require_var BASE_DOMAIN
  need aws
  need jq

  local zone_json zone_count zone_id
  zone_json="$(aws route53 list-hosted-zones --output json)"
  zone_count="$(jq -r --arg name "${BASE_DOMAIN}." \
    '[.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false)] | length' \
    <<<"$zone_json")"
  [[ "$zone_count" -eq 1 ]] || \
    die "BASE_DOMAIN=${BASE_DOMAIN} に完全一致する Route 53 Public Hosted Zone は1件必要です（検出: ${zone_count}件）"

  zone_id="$(jq -r --arg name "${BASE_DOMAIN}." \
    '.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false) | .Id | sub("^/hostedzone/"; "")' \
    <<<"$zone_json")"
  [[ -n "$zone_id" && "$zone_id" != null ]] || die "Public Hosted Zone ID を取得できません"
  printf '%s\n' "$zone_id"
}
load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE がありません。configs/environment.example をコピーしてください"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  require_var AWS_REGION; require_var CLUSTER_NAME; require_var BASE_DOMAIN; require_var INSTALL_DIR
}
mask_account() { sed -E 's/([0-9]{4})[0-9]{4}([0-9]{4})/\1****\2/g'; }
