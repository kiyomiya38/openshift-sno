#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"

umask 077

for command_name in base64 jq oc openssl sed sort tr; do
  phase6_require_command "$command_name"
done
phase6_require_file "$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
phase7_assert_target_cluster "$INSTALL_DIR/auth/kubeconfig"

printf 'Current nodes:\n'
oc get nodes -o wide || true
printf '\nCSR inventory:\n'
oc get csr

initial_nodes_json="$(oc get nodes -o json)"
phase6_assert_expected_node_subset "$initial_nodes_json"

mapfile -t pending_csrs < <(oc get csr -o json |
  jq -r '.items[] | select((.status.conditions // []) | length == 0) | .metadata.name')

request_files=()
cleanup_request_files() {
  if (( ${#request_files[@]} > 0 )); then
    rm -f -- "${request_files[@]}"
  fi
}
trap cleanup_request_files EXIT

approved_count=0
if (( ${#pending_csrs[@]} == 0 )); then
  printf '\nNo pending CSR exists at the start of this review pass.\n'
else
  printf '\nOnly approve requests whose node FQDN/IP matches the design table.\n'
  printf 'Expected nodes: control-plane-{0,1,2}.ocp.lab.k8study.com and worker-{0,1,2}.ocp.lab.k8study.com\n'

  for csr_name in "${pending_csrs[@]}"; do
    csr_json="$(oc get csr "$csr_name" -o json)"
    csr_uid="$(jq -er '.metadata.uid' <<<"$csr_json")"
    printf '\n===== CSR %s =====\n' "$csr_name"
    jq -r '["Signer: " + .spec.signerName, "Requestor: " + .spec.username] | .[]' <<<"$csr_json"

    request_file="$(mktemp)"
    request_files+=("$request_file")
    if ! jq -r '.spec.request' <<<"$csr_json" | base64 -d >"$request_file"; then
      phase6_error "Unable to decode CSR $csr_name."
    fi
    openssl req -in "$request_file" -noout -subject -text |
      sed -n '/Subject:/p;/Subject Alternative Name/{N;p;}' || true

    if ! phase6_csr_is_expected_node_request "$csr_json" "$request_file"; then
      printf 'NOT ELIGIBLE - do not approve: %s\n' "$PHASE6_CSR_ELIGIBILITY_REASON"
      printf 'No approval prompt is offered for this CSR. Investigate it before continuing.\n'
      continue
    fi
    printf 'Eligibility: PASS - this CSR exactly matches the node bootstrap design.\n'

    read -r -p "Type the exact CSR name to approve it, or press Enter to skip: " CONFIRM
    if [[ "$CONFIRM" == "$csr_name" ]]; then
      refreshed_csr_json="$(oc get csr "$csr_name" -o json)"
      [[ "$(jq -r '.metadata.uid' <<<"$refreshed_csr_json")" == "$csr_uid" ]] \
        || phase6_error "CSR $csr_name was replaced before approval."
      jq -e '((.status.conditions // []) | length) == 0' \
        <<<"$refreshed_csr_json" >/dev/null \
        || phase6_error "CSR $csr_name is no longer pending."
      if ! jq -r '.spec.request' <<<"$refreshed_csr_json" | base64 -d >"$request_file"; then
        phase6_error "Unable to re-decode CSR $csr_name before approval."
      fi
      phase6_csr_is_expected_node_request "$refreshed_csr_json" "$request_file" \
        || phase6_error "CSR $csr_name changed or failed revalidation: $PHASE6_CSR_ELIGIBILITY_REASON"
      oc adm certificate approve "$csr_name"
      approved_count=$((approved_count + 1))
    else
      printf 'Skipped %s.\n' "$csr_name"
    fi
  done
fi

node_json="$(oc get nodes -o json)"
phase6_assert_expected_node_subset "$node_json"
registered_nodes="$(jq '.items | length' <<<"$node_json")"
ready_nodes="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$node_json")"
csr_inventory_json="$(oc get csr -o json)"
remaining_pending="$(jq \
  '[.items[] | select((.status.conditions // []) | length == 0)] | length' \
  <<<"$csr_inventory_json")"
approved_not_issued="$(jq '[.items[] | select(
    any(.status.conditions[]?; .type == "Approved") and
    ((.status.certificate // "") | length == 0)
  )] | length' <<<"$csr_inventory_json")"
unresolved_csrs=$((remaining_pending + approved_not_issued))
inventory_complete=false
if phase6_expected_node_inventory_complete "$node_json"; then
  inventory_complete=true
fi

printf '\n=== CSR and node readiness gate ===\n'
printf 'CSRs approved in this pass: %d\n' "$approved_count"
printf 'Registered nodes: %s/6\n' "$registered_nodes"
printf 'Ready nodes: %s/6\n' "$ready_nodes"
printf 'Pending CSRs: %s\n' "$remaining_pending"
printf 'Approved but not issued CSRs: %s\n' "$approved_not_issued"
printf 'Unresolved CSRs: %s\n' "$unresolved_csrs"

if (( approved_count > 0 )); then
  printf 'WAIT: A CSR was approved in this pass; node readiness or a new serving CSR may still appear.\n'
  printf 'Do not run scripts/06-14-wait-for-install-complete.sh yet.\n'
  printf 'Next: wait 30 to 60 seconds, then run bash scripts/06-13-review-csrs.sh again.\n'
  exit 2
elif [[ "$inventory_complete" == true && "$ready_nodes" == 6 && "$unresolved_csrs" == 0 ]]; then
  printf 'CSR and node readiness gate PASSED.\n'
  printf 'Next: bash scripts/06-14-wait-for-install-complete.sh\n'
else
  printf 'WAIT: The exact six designed Ready nodes and zero unresolved CSRs are required.\n'
  printf 'Do not run scripts/06-14-wait-for-install-complete.sh yet.\n'
  printf 'Next: wait 30 to 60 seconds, then run bash scripts/06-13-review-csrs.sh again.\n'
  exit 2
fi
