#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig}"
TEST_NAMESPACE=nfs-storage-test
TEST_PVC=nfs-persistence
TEST_POD=nfs-persistence-test
DEPLOYMENTCONFIG_WARNING='Warning: apps.openshift.io/v1 DeploymentConfig is deprecated in v4.14+, unavailable in v4.10000+'

error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v oc >/dev/null 2>&1 || error 'oc is not installed.'
command -v jq >/dev/null 2>&1 || error 'jq is not installed.'
[[ -s "$KUBECONFIG_FILE" ]] || error "Missing kubeconfig: $KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
phase7_assert_target_cluster "$KUBECONFIG_FILE"

all_pvs_json="$(oc get persistentvolumes -o json)" \
  || error 'Unable to list PersistentVolumes.'
pv_names_text="$(jq -r --arg namespace "$TEST_NAMESPACE" --arg claim "$TEST_PVC" '
  .items[] |
  select(.spec.claimRef.namespace == $namespace and .spec.claimRef.name == $claim) |
  .metadata.name
' <<<"$all_pvs_json")" \
  || error 'Unable to select matching PersistentVolumes.'
pv_names=()
[[ -z "$pv_names_text" ]] || mapfile -t pv_names <<<"$pv_names_text"

namespace_json="$(phase7_optional_json namespace/$TEST_NAMESPACE)"
if [[ -z "$namespace_json" ]]; then
  (( ${#pv_names[@]} == 0 )) \
    || error "Namespace $TEST_NAMESPACE is absent, but a matching PersistentVolume remains."
  printf 'NFS test namespace does not exist. Nothing to clean up.\n'
  exit 0
fi

phase7_assert_owned_json "$namespace_json" "namespace/$TEST_NAMESPACE"
phase7_assert_owned_if_exists "persistentvolumeclaim/$TEST_PVC" "$TEST_NAMESPACE"
phase7_assert_owned_if_exists "pod/$TEST_POD" "$TEST_NAMESPACE"

workloads_json="$(
  oc get all -n "$TEST_NAMESPACE" -o json \
    2> >(grep -vFx "$DEPLOYMENTCONFIG_WARNING" >&2)
)" \
  || error "Unable to inspect workloads in namespace $TEST_NAMESPACE."
jq -e --arg pod "$TEST_POD" '
  all(.items[]; .kind == "Pod" and .metadata.name == $pod)
' <<<"$workloads_json" >/dev/null \
  || error "Namespace $TEST_NAMESPACE contains an unexpected workload; refusing to delete it."

claims_json="$(oc get persistentvolumeclaims -n "$TEST_NAMESPACE" -o json)" \
  || error "Unable to inspect PVCs in namespace $TEST_NAMESPACE."
jq -e --arg claim "$TEST_PVC" '
  all(.items[]; .metadata.name == $claim)
' <<<"$claims_json" >/dev/null \
  || error "Namespace $TEST_NAMESPACE contains an unexpected PVC; refusing to delete it."

for pv_name in "${pv_names[@]}"; do
  pv_json="$(jq -er --arg name "$pv_name" \
    '.items[] | select(.metadata.name == $name)' <<<"$all_pvs_json")" \
    || error "Unable to inspect PersistentVolume $pv_name."
  jq -e '
    .spec.storageClassName == "nfs-rwx" and
    .spec.nfs.server == "10.80.40.41" and
    (.spec.nfs.path | startswith("/srv/nfs/openshift/"))
  ' <<<"$pv_json" >/dev/null \
    || error "PersistentVolume $pv_name does not match the expected lab configuration."
done

printf 'This deletes the lab-owned test Pod, PVC, dynamic PV, and namespace %s.\n' "$TEST_NAMESPACE"
read -r -p 'Type DELETE-NFS-PERSISTENCE-TEST to continue: ' CONFIRM
[[ "$CONFIRM" == DELETE-NFS-PERSISTENCE-TEST ]] || {
  printf 'NFS test cleanup cancelled.\n'
  exit 0
}

oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" \
  --ignore-not-found=true --wait=true --timeout=5m >/dev/null
oc delete persistentvolumeclaim "$TEST_PVC" -n "$TEST_NAMESPACE" \
  --ignore-not-found=true --wait=true --timeout=5m >/dev/null

remaining_pv_names=()
for _ in {1..60}; do
  current_pvs_json="$(oc get persistentvolumes -o json)" \
    || error 'Unable to verify PersistentVolume reclamation.'
  remaining_pv_names_text="$(jq -r \
    --arg namespace "$TEST_NAMESPACE" --arg claim "$TEST_PVC" '
      .items[] |
      select(.spec.claimRef.namespace == $namespace and .spec.claimRef.name == $claim) |
      .metadata.name
    ' <<<"$current_pvs_json")" \
    || error 'Unable to select remaining PersistentVolumes.'
  remaining_pv_names=()
  [[ -z "$remaining_pv_names_text" ]] \
    || mapfile -t remaining_pv_names <<<"$remaining_pv_names_text"
  (( ${#remaining_pv_names[@]} == 0 )) && break
  sleep 5
done

if (( ${#remaining_pv_names[@]} != 0 )); then
  printf 'PersistentVolumes still present: %s\n' "${remaining_pv_names[*]}" >&2
  error 'The dynamic PersistentVolume was not reclaimed within five minutes.'
fi

printf 'PASS: No dynamic PV remains for %s/%s.\n' "$TEST_NAMESPACE" "$TEST_PVC"

workloads_json="$(
  oc get all -n "$TEST_NAMESPACE" -o json \
    2> >(grep -vFx "$DEPLOYMENTCONFIG_WARNING" >&2)
)" \
  || error "Unable to recheck workloads in namespace $TEST_NAMESPACE."
claims_json="$(oc get persistentvolumeclaims -n "$TEST_NAMESPACE" -o json)" \
  || error "Unable to recheck PVCs in namespace $TEST_NAMESPACE."
jq -e '.items | length == 0' <<<"$workloads_json" >/dev/null \
  || error "Workloads remain in namespace $TEST_NAMESPACE; refusing to delete it."
jq -e '.items | length == 0' <<<"$claims_json" >/dev/null \
  || error "PVCs remain in namespace $TEST_NAMESPACE; refusing to delete it."

oc delete namespace "$TEST_NAMESPACE" --wait=true --timeout=5m >/dev/null

for resource_name in \
  storageclass/nfs-rwx \
  persistentvolume/nfs-subdir-provisioner-root; do
  retained_json="$(phase7_optional_json "$resource_name")"
  [[ -n "$retained_json" ]] || error "Expected retained resource is missing: $resource_name"
  phase7_assert_owned_json "$retained_json" "$resource_name"
done

for resource_name in \
  persistentvolumeclaim/nfs-subdir-provisioner-root \
  deployment.apps/nfs-subdir-external-provisioner; do
  retained_json="$(phase7_optional_json "$resource_name" nfs-provisioner)"
  [[ -n "$retained_json" ]] \
    || error "Expected retained resource is missing: $resource_name in namespace nfs-provisioner"
  phase7_assert_owned_json "$retained_json" "$resource_name in namespace nfs-provisioner"
done

retained_root_pv_json="$(oc get persistentvolume nfs-subdir-provisioner-root -o json)"
retained_root_pvc_json="$(oc get persistentvolumeclaim nfs-subdir-provisioner-root \
  -n nfs-provisioner -o json)"
retained_storage_class_json="$(oc get storageclass nfs-rwx -o json)"
jq -e '.status.phase == "Bound"' <<<"$retained_root_pv_json" >/dev/null \
  || error 'The retained NFS root PV is not Bound.'
jq -e '.status.phase == "Bound"' <<<"$retained_root_pvc_json" >/dev/null \
  || error 'The retained NFS root PVC is not Bound.'
jq -e '
  .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "false"
' <<<"$retained_storage_class_json" >/dev/null \
  || error 'The retained nfs-rwx StorageClass is unexpectedly default.'

oc wait --for=condition=Available \
  deployment/nfs-subdir-external-provisioner \
  -n nfs-provisioner --timeout=30s >/dev/null \
  || error 'The retained NFS provisioner is not Available.'

printf 'NFS persistence test cleanup PASSED.\n'
printf 'The test Pod, PVC, dynamically provisioned PV, and namespace were removed.\n'
