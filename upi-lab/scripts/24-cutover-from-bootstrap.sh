#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

phase6_require_command ansible-playbook
phase6_require_file "$INSTALL_DIR/bootstrap-complete.ok"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/pre-bootstrap-removal.yml"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/steady-state.yml"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/validate-steady-state.yml"

install -d -m 700 "$(dirname -- "$CLUSTER_STAGE_FILE")"
printf 'steady\n' >"$CLUSTER_STAGE_FILE"
chmod 600 "$CLUSTER_STAGE_FILE"

printf 'HAProxy and DNS Bootstrap cutover PASSED.\n'
printf 'Next: bash scripts/25-plan-bootstrap-removal.sh\n'

