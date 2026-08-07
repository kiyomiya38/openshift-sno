#!/usr/bin/env bash

PHASE7_EXPECTED_API_SERVER="${PHASE7_EXPECTED_API_SERVER:-https://api.ocp.lab.k8study.com:6443}"
PHASE7_ASSET_ROOT="${PHASE7_ASSET_ROOT:-$HOME/.local/share/openshift-upi-lab}"
PHASE7_METADATA_FILE="${PHASE7_METADATA_FILE:-$PHASE7_ASSET_ROOT/install/metadata.json}"

phase7_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

phase7_optional_json() {
  local resource_name="$1"
  local namespace_name="${2:-}"
  local resource_json

  if [[ -n "$namespace_name" ]]; then
    resource_json="$(oc get "$resource_name" -n "$namespace_name" \
      --ignore-not-found -o json)" \
      || phase7_error "Failed to query $resource_name in namespace $namespace_name."
  else
    resource_json="$(oc get "$resource_name" --ignore-not-found -o json)" \
      || phase7_error "Failed to query $resource_name."
  fi

  printf '%s' "$resource_json"
}

phase7_assert_owned_json() {
  local resource_json="$1"
  local resource_description="$2"
  local owner_label

  owner_label="$(jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""' \
    <<<"$resource_json")"
  [[ "$owner_label" == openshift-upi-lab ]] \
    || phase7_error "$resource_description exists but is not labeled for openshift-upi-lab."
}

phase7_assert_owned_if_exists() {
  local resource_name="$1"
  local namespace_name="${2:-}"
  local resource_json

  resource_json="$(phase7_optional_json "$resource_name" "$namespace_name")"
  [[ -z "$resource_json" ]] && return 0

  if [[ -n "$namespace_name" ]]; then
    phase7_assert_owned_json "$resource_json" "$resource_name in namespace $namespace_name"
  else
    phase7_assert_owned_json "$resource_json" "$resource_name"
  fi
}

phase7_assert_target_cluster() {
  local kubeconfig_file="$1"
  local expected_cluster_id actual_cluster_id actual_server current_context current_user

  command -v jq >/dev/null 2>&1 || phase7_error 'jq is not installed.'
  command -v oc >/dev/null 2>&1 || phase7_error 'oc is not installed.'
  [[ -s "$kubeconfig_file" ]] || phase7_error "Missing kubeconfig: $kubeconfig_file"
  [[ -s "$PHASE7_METADATA_FILE" ]] \
    || phase7_error "Missing installer metadata: $PHASE7_METADATA_FILE"

  export KUBECONFIG="$kubeconfig_file"

  actual_server="$(oc whoami --show-server)" \
    || phase7_error 'Unable to read the current OpenShift API server.'
  [[ "$actual_server" == "$PHASE7_EXPECTED_API_SERVER" ]] \
    || phase7_error "Unexpected OpenShift API server: $actual_server"

  oc get --raw=/readyz >/dev/null \
    || phase7_error 'The target OpenShift API is not ready.'

  expected_cluster_id="$(jq -er '.clusterID' "$PHASE7_METADATA_FILE")" \
    || phase7_error 'Installer metadata has no valid clusterID.'
  actual_cluster_id="$(oc get clusterversion version \
    -o jsonpath='{.spec.clusterID}')" \
    || phase7_error 'Unable to read the active OpenShift cluster ID.'
  [[ -n "$actual_cluster_id" && "$actual_cluster_id" == "$expected_cluster_id" ]] \
    || phase7_error 'The active cluster ID does not match the local installer metadata.'

  current_context="$(oc config current-context)" \
    || phase7_error 'Unable to read the current kubeconfig context.'
  current_user="$(oc whoami)" \
    || phase7_error 'Unable to read the current OpenShift identity.'

  printf 'Target API: %s\n' "$actual_server"
  printf 'Cluster ID: %s\n' "$actual_cluster_id"
  printf 'Context: %s\n' "$current_context"
  printf 'Identity: %s\n' "$current_user"
}
