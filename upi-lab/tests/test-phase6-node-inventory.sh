#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/phase6-common.sh
source "$LAB_ROOT/scripts/lib/phase6-common.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for the Phase 6 node inventory test.\n' >&2
  exit 1
}

exact_nodes="$(jq -cn '
  def node($name; $ip; $role): {
    metadata: {
      name: $name,
      labels: {("node-role.kubernetes.io/" + $role): ""}
    },
    status: {
      addresses: [{type: "InternalIP", address: $ip}],
      conditions: [{type: "Ready", status: "True"}]
    }
  };
  {items: [
    node("control-plane-0.ocp.lab.k8study.com"; "10.80.10.10"; "control-plane"),
    node("control-plane-1.ocp.lab.k8study.com"; "10.80.20.10"; "control-plane"),
    node("control-plane-2.ocp.lab.k8study.com"; "10.80.30.10"; "control-plane"),
    node("worker-0.ocp.lab.k8study.com"; "10.80.10.20"; "worker"),
    node("worker-1.ocp.lab.k8study.com"; "10.80.20.20"; "worker"),
    node("worker-2.ocp.lab.k8study.com"; "10.80.30.20"; "worker")
  ]}
')"

phase6_assert_expected_node_subset "$exact_nodes"
phase6_expected_node_inventory_complete "$exact_nodes" || {
  printf 'ERROR: The exact designed node inventory was rejected.\n' >&2
  exit 1
}

partial_nodes="$(jq '.items = .items[0:5]' <<<"$exact_nodes")"
phase6_assert_expected_node_subset "$partial_nodes"
if phase6_expected_node_inventory_complete "$partial_nodes"; then
  printf 'ERROR: An incomplete expected-node subset was accepted as complete.\n' >&2
  exit 1
fi

wrong_ip_nodes="$(jq '(.items[] | select(.metadata.name == "worker-2.ocp.lab.k8study.com")
  | .status.addresses[0].address) = "10.80.30.99"' <<<"$exact_nodes")"
if (phase6_assert_expected_node_subset "$wrong_ip_nodes" >/dev/null 2>&1); then
  printf 'ERROR: A node with the wrong InternalIP was accepted.\n' >&2
  exit 1
fi

wrong_role_nodes="$(jq '(.items[] | select(.metadata.name == "worker-2.ocp.lab.k8study.com")
  | .metadata.labels) = {"node-role.kubernetes.io/control-plane": ""}' <<<"$exact_nodes")"
if (phase6_assert_expected_node_subset "$wrong_role_nodes" >/dev/null 2>&1); then
  printf 'ERROR: A node with the wrong role was accepted.\n' >&2
  exit 1
fi

rogue_nodes="$(jq '(.items[] | select(.metadata.name == "worker-2.ocp.lab.k8study.com")
  | .metadata.name) = "rogue.ocp.lab.k8study.com"' <<<"$exact_nodes")"
if (phase6_assert_expected_node_subset "$rogue_nodes" >/dev/null 2>&1); then
  printf 'ERROR: An unexpected node name was accepted.\n' >&2
  exit 1
fi

printf 'Phase 6 exact node inventory safety regression PASSED.\n'
