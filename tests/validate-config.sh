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
if [[ -f "$root/configs/environment" ]]; then
  # shellcheck source=/dev/null
  source "$root/configs/environment"
  case "${BASE_DOMAIN:-}" in
    ""|example.com|example.net|example.org|example.jp)
      echo "FAIL: configs/environment の BASE_DOMAIN を所有する実ドメインへ変更してください" >&2
      exit 1
      ;;
  esac
  if [[ -f "${INSTALL_DIR:-}/install-config.yaml" ]] && grep -Eq '^baseDomain: (example\.com|example\.net|example\.org|example\.jp)$' "${INSTALL_DIR}/install-config.yaml"; then
    echo "FAIL: 生成済み install-config.yaml に例示ドメインが残っています" >&2
    exit 1
  fi
fi
if command -v shellcheck >/dev/null; then shellcheck -x "$root"/scripts/*.sh "$root"/tests/*.sh; else echo 'SKIP: shellcheck not installed'; fi
if command -v ruby >/dev/null; then ruby -e 'require "yaml"; ARGV.each{|f| YAML.load_file(f)}' "$root"/manifests/*.yaml; else echo 'SKIP: YAML parser not installed'; fi
echo 'PASS: static validation'
