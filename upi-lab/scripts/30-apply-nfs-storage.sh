#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"
MANIFEST_FILE="$PROJECT_DIR/manifests/nfs-storage/provisioner.yaml"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig}"
NAMESPACE=nfs-provisioner
DEPLOYMENT=nfs-subdir-external-provisioner
ROOT_VOLUME=nfs-subdir-provisioner-root

error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in jq oc; do
  command -v "$command_name" >/dev/null 2>&1 || error "$command_name is not installed."
done
[[ -s "$KUBECONFIG_FILE" ]] || error "Missing kubeconfig: $KUBECONFIG_FILE"
[[ -s "$MANIFEST_FILE" ]] || error "Missing manifest: $MANIFEST_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
phase7_assert_target_cluster "$KUBECONFIG_FILE"

nodes_json="$(oc get nodes -o json)"
total_nodes="$(jq '.items | length' <<<"$nodes_json")"
ready_nodes="$(jq \
  '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' \
  <<<"$nodes_json")"
[[ "$total_nodes" == 6 ]] || error "Expected six total nodes, found $total_nodes."
[[ "$ready_nodes" == 6 ]] || error "Expected six Ready nodes, found $ready_nodes."

pending_csrs="$(oc get csr -o json |
  jq '[.items[] | select((.status.conditions // []) | length == 0)] | length')"
[[ "$pending_csrs" == 0 ]] || error "Pending CSRs remain: $pending_csrs."

[[ "$(oc auth can-i create storageclasses.storage.k8s.io 2>/dev/null)" == yes ]] \
  || error 'The current identity cannot create StorageClasses.'
[[ "$(oc auth can-i create clusterroles.rbac.authorization.k8s.io 2>/dev/null)" == yes ]] \
  || error 'The current identity cannot create ClusterRoles.'
[[ "$(oc auth can-i create persistentvolumes 2>/dev/null)" == yes ]] \
  || error 'The current identity cannot create PersistentVolumes.'

for resource_name in \
  namespace/nfs-provisioner \
  storageclass/nfs-rwx \
  persistentvolume/$ROOT_VOLUME \
  clusterrole/openshift-upi-lab-nfs-provisioner \
  clusterrolebinding/openshift-upi-lab-nfs-provisioner; do
  phase7_assert_owned_if_exists "$resource_name"
done

provisioner_namespace_json="$(phase7_optional_json namespace/nfs-provisioner)"
if [[ -n "$provisioner_namespace_json" ]]; then
  for resource_name in \
    serviceaccount/nfs-subdir-external-provisioner \
    role/nfs-provisioner-leader-lock \
    rolebinding/nfs-provisioner-leader-lock \
    persistentvolumeclaim/$ROOT_VOLUME \
    deployment.apps/$DEPLOYMENT; do
    phase7_assert_owned_if_exists "$resource_name" "$NAMESPACE"
  done
fi

existing_root_pv_json="$(phase7_optional_json persistentvolume/$ROOT_VOLUME)"
if [[ -n "$existing_root_pv_json" ]]; then
  jq -e '
    .spec.persistentVolumeReclaimPolicy == "Retain" and
    (.spec.storageClassName // "") == "" and
    .spec.claimRef.namespace == "nfs-provisioner" and
    .spec.claimRef.name == "nfs-subdir-provisioner-root" and
    .spec.nfs.server == "10.80.40.41" and
    .spec.nfs.path == "/srv/nfs/openshift"
  ' <<<"$existing_root_pv_json" >/dev/null \
    || error 'The existing lab-owned root PV has immutable configuration drift.'
fi

existing_storage_class_json="$(phase7_optional_json storageclass/nfs-rwx)"
if [[ -n "$existing_storage_class_json" ]]; then
  jq -e '
    .provisioner == "lab.k8study.com/nfs-subdir-external-provisioner" and
    .reclaimPolicy == "Delete" and
    .allowVolumeExpansion == false and
    .volumeBindingMode == "Immediate" and
    .parameters.onDelete == "delete" and
    (.mountOptions | index("nfsvers=4.1")) != null and
    (.mountOptions | index("proto=tcp")) != null
  ' <<<"$existing_storage_class_json" >/dev/null \
    || error 'The existing lab-owned StorageClass has immutable configuration drift.'
fi

existing_binding_json="$(phase7_optional_json \
  clusterrolebinding/openshift-upi-lab-nfs-provisioner)"
if [[ -n "$existing_binding_json" ]]; then
  jq -e '
    .roleRef.apiGroup == "rbac.authorization.k8s.io" and
    .roleRef.kind == "ClusterRole" and
    .roleRef.name == "openshift-upi-lab-nfs-provisioner" and
    (.subjects | length == 1) and
    .subjects[0].kind == "ServiceAccount" and
    .subjects[0].name == "nfs-subdir-external-provisioner" and
    .subjects[0].namespace == "nfs-provisioner"
  ' <<<"$existing_binding_json" >/dev/null \
    || error 'The existing lab-owned ClusterRoleBinding has immutable role or subject drift.'
fi

if [[ -n "$provisioner_namespace_json" ]]; then
  existing_root_pvc_json="$(phase7_optional_json \
    persistentvolumeclaim/$ROOT_VOLUME "$NAMESPACE")"
  if [[ -n "$existing_root_pvc_json" ]]; then
    jq -e '
      (.spec.storageClassName // "") == "" and
      .spec.volumeName == "nfs-subdir-provisioner-root" and
      (.spec.accessModes | index("ReadWriteMany")) != null
    ' <<<"$existing_root_pvc_json" >/dev/null \
      || error 'The existing lab-owned root PVC has immutable configuration drift.'
  fi
fi

printf 'This installs one community NFS provisioner and the non-default nfs-rwx StorageClass.\n'
printf 'NFS server: 10.80.40.41:/srv/nfs/openshift\n'
printf 'The provisioner runs under restricted-v2 through a dedicated retained root PV/PVC.\n'
read -r -p 'Type APPLY-NFS-STORAGE to continue: ' CONFIRM
[[ "$CONFIRM" == APPLY-NFS-STORAGE ]] || {
  printf 'NFS StorageClass installation cancelled.\n'
  exit 0
}

oc apply -f "$MANIFEST_FILE"

oc wait --for=jsonpath='{.status.phase}'=Bound \
  persistentvolumeclaim/"$ROOT_VOLUME" \
  -n "$NAMESPACE" --timeout=5m \
  || error 'The dedicated NFS root PVC did not become Bound.'

if ! oc rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=5m; then
  oc get pods -n "$NAMESPACE" -o wide >&2 || true
  oc describe deployment/"$DEPLOYMENT" -n "$NAMESPACE" >&2 || true
  error 'NFS provisioner did not become available.'
fi

pod_name="$(oc get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/name=nfs-subdir-external-provisioner \
  -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')"
scc_name="$(oc get pod "$pod_name" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
[[ "$scc_name" == restricted-v2 ]] \
  || error "Expected restricted-v2 SCC, found ${scc_name:-none}."

pod_json="$(oc get pod "$pod_name" -n "$NAMESPACE" -o json)"
run_as_user="$(jq -er '
  [.spec.containers[] |
    select(.name == "nfs-subdir-external-provisioner") |
    .securityContext.runAsUser][0]
' <<<"$pod_json")" \
  || error 'OpenShift did not assign a runtime UID to the provisioner.'
[[ "$run_as_user" =~ ^[0-9]+$ && "$run_as_user" -ne 0 ]] \
  || error "The provisioner received an invalid runtime UID: $run_as_user."

deployment_json="$(oc get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json)"
jq -e --arg claim "$ROOT_VOLUME" '
  any(.spec.template.spec.volumes[]?;
    .persistentVolumeClaim.claimName == $claim) and
  all(.spec.template.spec.volumes[]?; has("nfs") | not)
' <<<"$deployment_json" >/dev/null \
  || error 'The provisioner must mount the dedicated PVC, not a direct NFS volume.'

root_pv_json="$(oc get persistentvolume "$ROOT_VOLUME" -o json)"
jq -e '
  .status.phase == "Bound" and
  .spec.persistentVolumeReclaimPolicy == "Retain" and
  (.spec.storageClassName // "") == "" and
  .spec.nfs.server == "10.80.40.41" and
  .spec.nfs.path == "/srv/nfs/openshift" and
  (.spec.mountOptions | index("nfsvers=4.1")) != null and
  (.spec.mountOptions | index("proto=tcp")) != null
' <<<"$root_pv_json" >/dev/null \
  || error 'The dedicated NFS root PV does not match the expected configuration.'

storage_class_json="$(oc get storageclass nfs-rwx -o json)"
jq -e '
  .provisioner == "lab.k8study.com/nfs-subdir-external-provisioner" and
  .reclaimPolicy == "Delete" and
  .allowVolumeExpansion == false and
  .volumeBindingMode == "Immediate" and
  (.mountOptions | index("nfsvers=4.1")) != null and
  (.mountOptions | index("proto=tcp")) != null and
  .parameters.onDelete == "delete" and
  .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "false"
' <<<"$storage_class_json" >/dev/null \
  || error 'The nfs-rwx StorageClass does not match the expected configuration.'

printf '\nNFS StorageClass installation PASSED.\n'
printf 'Provisioner pod: %s\n' "$pod_name"
printf 'OpenShift SCC: %s\n' "$scc_name"
printf 'Runtime UID: %s\n' "$run_as_user"
printf 'Root PV/PVC: %s (Bound, Retain)\n' "$ROOT_VOLUME"
printf 'StorageClass: nfs-rwx (non-default, NFSv4.1)\n'
printf 'Test target: dynamically provisioned ReadWriteMany volume\n'
printf 'Next: bash scripts/31-validate-nfs-storage.sh\n'
