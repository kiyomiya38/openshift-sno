#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need openshift-install
reject_example_domain
[[ -s "$INSTALL_DIR/install-config.yaml" ]] || die "先に scripts/04-create-install-config.sh を実行してください"
mkdir -p "$ROOT_DIR/logs"; umask 077
log="$ROOT_DIR/logs/create-cluster-$(date +%Y%m%d-%H%M%S).log"
info "debug ログには機密情報が含まれ得ます。共有前に必ず確認してください: $log"
openshift-install create cluster --dir "$INSTALL_DIR" --log-level=debug 2>&1 | tee "$log"
