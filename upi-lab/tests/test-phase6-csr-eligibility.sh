#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/phase6-common.sh
source "$LAB_ROOT/scripts/lib/phase6-common.sh"

for command_name in jq openssl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required for the Phase 6 CSR eligibility test.\n' "$command_name" >&2
    exit 1
  }
done

temporary_directory="$(mktemp -d)"
cleanup() {
  rm -f -- \
    "$temporary_directory/key.pem" \
    "$temporary_directory/client.pem" \
    "$temporary_directory/serving.pem" \
    "$temporary_directory/extra-san.pem" \
    "$temporary_directory/wrong-ip.pem"
  rmdir -- "$temporary_directory"
}
trap cleanup EXIT

node_fqdn='worker-2.ocp.lab.k8study.com'
node_subject='/O=system:nodes/CN=system:node:worker-2.ocp.lab.k8study.com'
openssl genpkey -algorithm ED25519 -out "$temporary_directory/key.pem" 2>/dev/null
openssl req -new -key "$temporary_directory/key.pem" \
  -out "$temporary_directory/client.pem" -subj "$node_subject"
openssl req -new -key "$temporary_directory/key.pem" \
  -out "$temporary_directory/serving.pem" -subj "$node_subject" \
  -addext "subjectAltName=DNS:${node_fqdn},IP:10.80.30.20"
openssl req -new -key "$temporary_directory/key.pem" \
  -out "$temporary_directory/extra-san.pem" -subj "$node_subject" \
  -addext "subjectAltName=DNS:${node_fqdn},DNS:unexpected.example,IP:10.80.30.20"
openssl req -new -key "$temporary_directory/key.pem" \
  -out "$temporary_directory/wrong-ip.pem" -subj "$node_subject" \
  -addext "subjectAltName=DNS:${node_fqdn},IP:10.80.30.99"

client_json="$(jq -cn '{spec: {
  signerName: "kubernetes.io/kube-apiserver-client-kubelet",
  username: "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper",
  usages: ["digital signature", "client auth"]
}}')"
serving_json="$(jq -cn --arg node "$node_fqdn" '{spec: {
  signerName: "kubernetes.io/kubelet-serving",
  username: ("system:node:" + $node),
  usages: ["digital signature", "server auth"]
}}')"
client_with_key_encipherment_json="$(jq \
  '.spec.usages += ["key encipherment"]' <<<"$client_json")"
serving_with_key_encipherment_json="$(jq \
  '.spec.usages += ["key encipherment"]' <<<"$serving_json")"

phase6_csr_is_expected_node_request \
  "$client_json" "$temporary_directory/client.pem" || {
  printf 'ERROR: A valid kubelet client CSR was rejected: %s\n' \
    "$PHASE6_CSR_ELIGIBILITY_REASON" >&2
  exit 1
}
phase6_csr_is_expected_node_request \
  "$serving_json" "$temporary_directory/serving.pem" || {
  printf 'ERROR: A valid kubelet serving CSR was rejected: %s\n' \
    "$PHASE6_CSR_ELIGIBILITY_REASON" >&2
  exit 1
}
phase6_csr_is_expected_node_request \
  "$client_with_key_encipherment_json" "$temporary_directory/client.pem" || {
  printf 'ERROR: A valid kubelet client CSR with key encipherment was rejected: %s\n' \
    "$PHASE6_CSR_ELIGIBILITY_REASON" >&2
  exit 1
}
phase6_csr_is_expected_node_request \
  "$serving_with_key_encipherment_json" "$temporary_directory/serving.pem" || {
  printf 'ERROR: A valid kubelet serving CSR with key encipherment was rejected: %s\n' \
    "$PHASE6_CSR_ELIGIBILITY_REASON" >&2
  exit 1
}
serving_reordered_usages_json="$(jq \
  '.spec.usages = ["server auth", "digital signature"]' <<<"$serving_json")"
phase6_csr_is_expected_node_request \
  "$serving_reordered_usages_json" "$temporary_directory/serving.pem" || {
  printf 'ERROR: A valid serving CSR with reordered usages was rejected: %s\n' \
    "$PHASE6_CSR_ELIGIBILITY_REASON" >&2
  exit 1
}

if phase6_csr_is_expected_node_request \
  "$serving_json" "$temporary_directory/extra-san.pem"; then
  printf 'ERROR: A serving CSR with an additional DNS SAN was accepted.\n' >&2
  exit 1
fi
if phase6_csr_is_expected_node_request \
  "$serving_json" "$temporary_directory/wrong-ip.pem"; then
  printf 'ERROR: A serving CSR with the wrong IP SAN was accepted.\n' >&2
  exit 1
fi

unexpected_usage_json="$(jq \
  '.spec.usages += ["cert sign"]' <<<"$serving_json")"
if phase6_csr_is_expected_node_request \
  "$unexpected_usage_json" "$temporary_directory/serving.pem"; then
  printf 'ERROR: A serving CSR with an additional usage was accepted.\n' >&2
  exit 1
fi

missing_usage_json="$(jq \
  '.spec.usages = ["server auth"]' <<<"$serving_json")"
if phase6_csr_is_expected_node_request \
  "$missing_usage_json" "$temporary_directory/serving.pem"; then
  printf 'ERROR: A serving CSR without digital signature usage was accepted.\n' >&2
  exit 1
fi

duplicate_usage_json="$(jq \
  '.spec.usages += ["digital signature"]' <<<"$serving_json")"
if phase6_csr_is_expected_node_request \
  "$duplicate_usage_json" "$temporary_directory/serving.pem"; then
  printf 'ERROR: A serving CSR with a duplicate usage was accepted.\n' >&2
  exit 1
fi

if phase6_csr_is_expected_node_request \
  "$client_json" "$temporary_directory/serving.pem"; then
  printf 'ERROR: A kubelet client CSR with a SAN was accepted.\n' >&2
  exit 1
fi

wrong_requestor_json="$(jq \
  '.spec.username = "system:node:worker-1.ocp.lab.k8study.com"' \
  <<<"$serving_json")"
if phase6_csr_is_expected_node_request \
  "$wrong_requestor_json" "$temporary_directory/serving.pem"; then
  printf 'ERROR: A serving CSR with the wrong Requestor was accepted.\n' >&2
  exit 1
fi

unknown_signer_json="$(jq \
  '.spec.signerName = "kubernetes.io/kube-apiserver-client"' \
  <<<"$client_json")"
if phase6_csr_is_expected_node_request \
  "$unknown_signer_json" "$temporary_directory/client.pem"; then
  printf 'ERROR: A CSR with an ineligible signer was accepted.\n' >&2
  exit 1
fi

printf 'Phase 6 CSR eligibility safety regression PASSED.\n'
