#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"

umask 077

for command_name in ansible-playbook jq oc openshift-install; do
  phase6_require_command "$command_name"
done
phase6_require_complete_assets
phase6_require_file "$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
phase7_assert_target_cluster "$INSTALL_DIR/auth/kubeconfig"

metadata_infra_id="$(jq -er '.infraID | select(type == "string" and test("^[a-z0-9-]+$"))' \
  "$INSTALL_DIR/metadata.json")" \
  || phase6_error 'Installer metadata has no valid infraID.'
[[ "$metadata_infra_id" == "$INFRA_ID" ]] \
  || phase6_error 'Installer metadata infraID does not match cluster.env.'

node_json="$(oc get nodes -o json)"
phase6_assert_expected_node_inventory "$node_json"
registered_nodes="$(jq '.items | length' <<<"$node_json")"
ready_nodes="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$node_json")"
csr_inventory_json="$(oc get csr -o json)"
pending_csrs="$(jq \
  '[.items[] | select((.status.conditions // []) | length == 0)] | length' \
  <<<"$csr_inventory_json")"
approved_not_issued="$(jq '[.items[] | select(
    any(.status.conditions[]?; .type == "Approved") and
    ((.status.certificate // "") | length == 0)
  )] | length' <<<"$csr_inventory_json")"
unresolved_csrs=$((pending_csrs + approved_not_issued))

[[ "$registered_nodes" == 6 ]] || phase6_error \
  "Expected six registered nodes before install-complete, found $registered_nodes. Run scripts/06-13-review-csrs.sh again."
[[ "$ready_nodes" == 6 ]] || phase6_error \
  "Expected six Ready nodes before install-complete, found $ready_nodes. Run scripts/06-13-review-csrs.sh again."
[[ "$unresolved_csrs" == 0 ]] || phase6_error \
  "Expected zero unresolved CSRs before install-complete, found $unresolved_csrs (pending=$pending_csrs approved-not-issued=$approved_not_issued). Run scripts/06-13-review-csrs.sh again."

log_file="$INSTALL_DIR/install-complete.log"
: >"$log_file"
chmod 600 "$log_file"
openshift-install wait-for install-complete \
  --dir "$INSTALL_DIR" \
  --log-level=debug 2>&1 | tee "$log_file"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/stop-ignition.yml" \
  -e "ignition_infra_id=$INFRA_ID"

marker_temp="$(mktemp "$INSTALL_DIR/.install-complete.ok.XXXXXX")"
printf '%s\n' "$(date -Iseconds)" >"$marker_temp"
chmod 600 "$marker_temp"
mv -- "$marker_temp" "$INSTALL_DIR/install-complete.ok"

printf 'OpenShift installation completed and private Ignition HTTP serving was stopped.\n'
printf 'Next: bash scripts/06-15-validate-openshift-cluster.sh\n'
