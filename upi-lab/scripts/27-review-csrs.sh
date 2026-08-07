#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

for command_name in base64 jq oc openssl; do
  phase6_require_command "$command_name"
done
phase6_require_file "$INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

printf 'Current nodes:\n'
oc get nodes -o wide || true
printf '\nPending CSRs:\n'
oc get csr

mapfile -t pending_csrs < <(oc get csr -o json |
  jq -r '.items[] | select((.status.conditions // []) | length == 0) | .metadata.name')

if (( ${#pending_csrs[@]} == 0 )); then
  printf 'No pending CSR exists. Run this script again if new serving CSRs appear.\n'
  exit 0
fi

printf '\nOnly approve requests whose node FQDN/IP matches the design table.\n'
printf 'Expected nodes: control-plane-{0,1,2}.ocp.lab.k8study.com and worker-{0,1,2}.ocp.lab.k8study.com\n'

for csr_name in "${pending_csrs[@]}"; do
  csr_json="$(oc get csr "$csr_name" -o json)"
  printf '\n===== CSR %s =====\n' "$csr_name"
  jq -r '["Signer: " + .spec.signerName, "Requestor: " + .spec.username] | .[]' <<<"$csr_json"

  request_file="$(mktemp)"
  jq -r '.spec.request' <<<"$csr_json" | base64 -d >"$request_file"
  if ! openssl req -in "$request_file" -noout -subject -text |
    sed -n '/Subject:/p;/Subject Alternative Name/{N;p;}'; then
    rm -- "$request_file"
    phase6_error "Unable to decode CSR $csr_name."
  fi
  rm -- "$request_file"

  read -r -p "Type the exact CSR name to approve it, or press Enter to skip: " CONFIRM
  if [[ "$CONFIRM" == "$csr_name" ]]; then
    oc adm certificate approve "$csr_name"
  else
    printf 'Skipped %s.\n' "$csr_name"
  fi
done

printf '\nCSR review pass complete. Client approval can create a second serving CSR.\n'
printf 'Run this script again until verified CSRs are approved and all six nodes are Ready.\n'
printf 'Then run: bash scripts/28-wait-for-install-complete.sh\n'
