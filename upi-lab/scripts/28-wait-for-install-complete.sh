#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

for command_name in ansible-playbook jq oc openshift-install; do
  phase6_require_command "$command_name"
done
phase6_require_complete_assets
phase6_require_file "$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

ready_nodes="$(oc get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
[[ "$ready_nodes" == 6 ]] || phase6_error "Expected six Ready nodes before install-complete, found $ready_nodes. Review CSRs first."

log_file="$INSTALL_DIR/install-complete.log"
openshift-install wait-for install-complete \
  --dir "$INSTALL_DIR" \
  --log-level=debug 2>&1 | tee "$log_file"

printf '%s\n' "$(date -Iseconds)" >"$INSTALL_DIR/install-complete.ok"
chmod 600 "$INSTALL_DIR/install-complete.ok" "$log_file"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/stop-ignition.yml" \
  -e "ignition_infra_id=$INFRA_ID"

printf 'OpenShift installation completed and private Ignition HTTP serving was stopped.\n'
printf 'Next: bash scripts/29-validate-openshift-cluster.sh\n'
