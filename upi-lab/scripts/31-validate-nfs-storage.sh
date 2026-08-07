#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"
PVC_MANIFEST="$PROJECT_DIR/manifests/nfs-storage/test-pvc.yaml"
POD_MANIFEST="$PROJECT_DIR/manifests/nfs-storage/test-pod.yaml"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig}"
TEST_NAMESPACE=nfs-storage-test
TEST_PVC=nfs-persistence
TEST_POD=nfs-persistence-test
EXPECTED_MARKER=openshift-upi-lab-nfs-persistence-ok

error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in jq oc; do
  command -v "$command_name" >/dev/null 2>&1 || error "$command_name is not installed."
done
[[ -s "$KUBECONFIG_FILE" ]] || error "Missing kubeconfig: $KUBECONFIG_FILE"
[[ -s "$PVC_MANIFEST" ]] || error "Missing manifest: $PVC_MANIFEST"
[[ -s "$POD_MANIFEST" ]] || error "Missing manifest: $POD_MANIFEST"
export KUBECONFIG="$KUBECONFIG_FILE"
phase7_assert_target_cluster "$KUBECONFIG_FILE"

for resource_name in \
  namespace/nfs-provisioner \
  storageclass/nfs-rwx \
  persistentvolume/nfs-subdir-provisioner-root; do
  resource_json="$(phase7_optional_json "$resource_name")"
  [[ -n "$resource_json" ]] || error "Required resource does not exist: $resource_name"
  phase7_assert_owned_json "$resource_json" "$resource_name"
done

for resource_name in \
  persistentvolumeclaim/nfs-subdir-provisioner-root \
  deployment.apps/nfs-subdir-external-provisioner; do
  resource_json="$(phase7_optional_json "$resource_name" nfs-provisioner)"
  [[ -n "$resource_json" ]] \
    || error "Required resource does not exist: $resource_name in namespace nfs-provisioner"
  phase7_assert_owned_json "$resource_json" "$resource_name in namespace nfs-provisioner"
done

oc wait --for=condition=Available \
  deployment/nfs-subdir-external-provisioner \
  -n nfs-provisioner --timeout=30s >/dev/null \
  || error 'NFS provisioner is not Available.'
storage_class_json="$(oc get storageclass nfs-rwx -o json)"
jq -e '
  .provisioner == "lab.k8study.com/nfs-subdir-external-provisioner" and
  .reclaimPolicy == "Delete" and
  .allowVolumeExpansion == false and
  .volumeBindingMode == "Immediate" and
  .parameters.onDelete == "delete" and
  .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "false"
' <<<"$storage_class_json" >/dev/null \
  || error 'StorageClass nfs-rwx does not match the expected lab configuration.'

test_namespace_json="$(phase7_optional_json namespace/$TEST_NAMESPACE)"
if [[ -n "$test_namespace_json" ]]; then
  phase7_assert_owned_json "$test_namespace_json" "namespace/$TEST_NAMESPACE"

  for resource_name in \
    persistentvolumeclaim/$TEST_PVC \
    pod/$TEST_POD; do
    phase7_assert_owned_if_exists "$resource_name" "$TEST_NAMESPACE"
  done

  existing_pvc_json="$(phase7_optional_json \
    persistentvolumeclaim/$TEST_PVC "$TEST_NAMESPACE")"
  if [[ -n "$existing_pvc_json" ]]; then
    jq -e '
      .spec.storageClassName == "nfs-rwx" and
      (.spec.accessModes | index("ReadWriteMany")) != null
    ' <<<"$existing_pvc_json" >/dev/null \
      || error 'The existing test PVC does not match the expected lab configuration.'
  fi
fi

printf 'This creates a temporary RWX PVC and recreates its test Pod once.\n'
read -r -p 'Type RUN-NFS-PERSISTENCE-TEST to continue: ' CONFIRM
[[ "$CONFIRM" == RUN-NFS-PERSISTENCE-TEST ]] || {
  printf 'NFS persistence test cancelled.\n'
  exit 0
}

oc apply -f "$PVC_MANIFEST"
oc wait --for=jsonpath='{.status.phase}'=Bound \
  persistentvolumeclaim/"$TEST_PVC" \
  -n "$TEST_NAMESPACE" --timeout=5m

pv_name="$(oc get pvc "$TEST_PVC" -n "$TEST_NAMESPACE" \
  -o jsonpath='{.spec.volumeName}')"
[[ -n "$pv_name" ]] || error 'The test PVC has no bound PV.'

oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" \
  --ignore-not-found=true --wait=true --timeout=5m >/dev/null
oc apply -f "$POD_MANIFEST"
oc wait --for=condition=Ready pod/"$TEST_POD" \
  -n "$TEST_NAMESPACE" --timeout=5m
first_pod_uid="$(oc get pod "$TEST_POD" -n "$TEST_NAMESPACE" \
  -o jsonpath='{.metadata.uid}')"
first_scc="$(oc get pod "$TEST_POD" -n "$TEST_NAMESPACE" \
  -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
[[ "$first_scc" == restricted-v2 ]] \
  || error "Expected the test Pod to use restricted-v2, found ${first_scc:-none}."
first_runtime_uid="$(oc exec "$TEST_POD" -n "$TEST_NAMESPACE" -- id -u)"
[[ "$first_runtime_uid" =~ ^[0-9]+$ && "$first_runtime_uid" -ne 0 ]] \
  || error "The test Pod received an invalid runtime UID: $first_runtime_uid."

oc exec "$TEST_POD" -n "$TEST_NAMESPACE" -- /bin/sh -c \
  'printf "openshift-upi-lab-nfs-persistence-ok\n" > /data/persistence-marker && sync'
first_read="$(oc exec "$TEST_POD" -n "$TEST_NAMESPACE" -- \
  /bin/sh -c 'cat /data/persistence-marker')"
[[ "$first_read" == "$EXPECTED_MARKER" ]] \
  || error 'The first Pod could not read its NFS marker.'

oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" --wait=true --timeout=5m
oc apply -f "$POD_MANIFEST"
oc wait --for=condition=Ready pod/"$TEST_POD" \
  -n "$TEST_NAMESPACE" --timeout=5m
second_pod_uid="$(oc get pod "$TEST_POD" -n "$TEST_NAMESPACE" \
  -o jsonpath='{.metadata.uid}')"
[[ "$second_pod_uid" != "$first_pod_uid" ]] \
  || error 'The test Pod UID did not change after recreation.'

second_read="$(oc exec "$TEST_POD" -n "$TEST_NAMESPACE" -- \
  /bin/sh -c 'cat /data/persistence-marker')"
[[ "$second_read" == "$EXPECTED_MARKER" ]] \
  || error 'The recreated Pod could not read the persisted NFS marker.'

pv_json="$(oc get pv "$pv_name" -o json)"
jq -e '
  .spec.storageClassName == "nfs-rwx" and
  .spec.persistentVolumeReclaimPolicy == "Delete" and
  .spec.claimRef.namespace == "nfs-storage-test" and
  .spec.claimRef.name == "nfs-persistence" and
  .spec.nfs.server == "10.80.40.41" and
  (.spec.nfs.path | startswith("/srv/nfs/openshift/")) and
  (.spec.mountOptions | index("nfsvers=4.1")) != null and
  (.spec.mountOptions | index("proto=tcp")) != null and
  (.spec.accessModes | index("ReadWriteMany")) != null
' <<<"$pv_json" >/dev/null \
  || error 'The dynamically provisioned PV does not match the expected NFS design.'

oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" --wait=true --timeout=5m

printf '\nNFS StorageClass persistence validation PASSED.\n'
printf 'PVC: %s/%s (Bound)\n' "$TEST_NAMESPACE" "$TEST_PVC"
printf 'PV: %s\n' "$pv_name"
printf 'NFS path: %s\n' "$(jq -r '.spec.nfs.path' <<<"$pv_json")"
printf 'OpenShift SCC: %s\n' "$first_scc"
printf 'Non-root runtime UID: %s\n' "$first_runtime_uid"
printf 'A recreated Pod read the original marker successfully.\n'
printf 'The test PVC is retained for inspection.\n'
printf 'Next: bash scripts/32-cleanup-nfs-storage-test.sh\n'
