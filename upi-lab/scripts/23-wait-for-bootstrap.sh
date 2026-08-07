#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

phase6_require_command openshift-install
phase6_require_complete_assets
phase6_require_file "$INSTALL_DIR/auth/kubeconfig"

log_file="$INSTALL_DIR/bootstrap-complete.log"
printf 'Waiting for OpenShift bootstrap completion. Debug output: %s\n' "$log_file"

openshift-install wait-for bootstrap-complete \
  --dir "$INSTALL_DIR" \
  --log-level=debug 2>&1 | tee "$log_file"

printf '%s\n' "$(date -Iseconds)" >"$INSTALL_DIR/bootstrap-complete.ok"
chmod 600 "$INSTALL_DIR/bootstrap-complete.ok" "$log_file"

printf 'Bootstrap completion PASSED.\n'
printf 'Do not stop between HAProxy cutover and the Bootstrap removal Plan.\n'
printf 'Next: bash scripts/24-cutover-from-bootstrap.sh\n'

