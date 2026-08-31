#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in README.md LICENSE .gitignore configs/environment.example configs/install-config.example.yaml; do [[ -s "$root/$f" ]] || { echo "missing: $f" >&2; exit 1; }; done
for f in "$root"/scripts/*.sh "$root"/tests/*.sh; do bash -n "$f"; done
grep -Eq 'replicas:[[:space:]]*0' "$root/configs/install-config.example.yaml"
grep -Eq 'replicas:[[:space:]]*1' "$root/configs/install-config.example.yaml"
grep -q 'networkType: OVNKubernetes' "$root/configs/install-config.example.yaml"
grep -q 'install-config.yaml' "$root/.gitignore"; grep -q 'auth/' "$root/.gitignore"
test_public_hosted_zone_selection() {
  # shellcheck source=scripts/lib.sh
  source "$root/scripts/lib.sh"
  local BASE_DOMAIN="lab.invalid"
  local aws_response='{"HostedZones":[{"Id":"/hostedzone/ZPUBLIC","Name":"lab.invalid.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZPRIVATE","Name":"lab.invalid.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZNEAR","Name":"lab.invalid.example.","Config":{"PrivateZone":false}}]}'
  aws() { printf '%s\n' "$aws_response"; }

  [[ "$(get_public_hosted_zone_id)" == "ZPUBLIC" ]] || {
    echo "FAIL: exact public hosted zone was not selected" >&2
    exit 1
  }

  aws_response='{"HostedZones":[{"Id":"/hostedzone/ZPRIVATE","Name":"lab.invalid.","Config":{"PrivateZone":true}}]}'
  if (get_public_hosted_zone_id >/dev/null 2>&1); then
    echo "FAIL: a private hosted zone was accepted" >&2
    exit 1
  fi

  aws_response='{"HostedZones":[{"Id":"/hostedzone/Z1","Name":"lab.invalid.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/Z2","Name":"lab.invalid.","Config":{"PrivateZone":false}}]}'
  if (get_public_hosted_zone_id >/dev/null 2>&1); then
    echo "FAIL: duplicate public hosted zones were accepted" >&2
    exit 1
  fi
  unset -f aws
}
test_public_hosted_zone_selection
if [[ -f "$root/configs/environment" ]]; then
  # shellcheck source=/dev/null
  source "$root/configs/environment"
  case "${BASE_DOMAIN:-}" in
    ""|example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|example.jp|*.example.jp)
      echo "FAIL: configs/environment の BASE_DOMAIN を所有する実ドメインへ変更してください" >&2
      exit 1
      ;;
  esac
  if [[ -f "${INSTALL_DIR:-}/install-config.yaml" ]] && grep -Eq '^baseDomain: ([^.]+\.)*example\.(com|net|org|jp)$' "${INSTALL_DIR}/install-config.yaml"; then
    echo "FAIL: 生成済み install-config.yaml に例示ドメインが残っています" >&2
    exit 1
  fi
fi
if command -v shellcheck >/dev/null; then shellcheck -x "$root"/scripts/*.sh "$root"/tests/*.sh; else echo 'SKIP: shellcheck not installed'; fi
if command -v ruby >/dev/null; then ruby -e 'require "yaml"; ARGV.each{|f| YAML.load_file(f)}' "$root"/manifests/*.yaml; else echo 'SKIP: YAML parser not installed'; fi
echo 'PASS: static validation'
