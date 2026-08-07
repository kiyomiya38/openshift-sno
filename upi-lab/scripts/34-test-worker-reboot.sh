#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"

EXPECTED_AWS_REGION=ap-northeast-3
EXPECTED_API_SERVER=https://api.ocp.lab.k8study.com:6443
EXPECTED_TERRAFORM_DIR="$PHASE6_REPO_DIR/terraform"
EXPECTED_INSTALL_DIR="$HOME/.local/share/openshift-upi-lab/install"
EXPECTED_METADATA_FILE="$EXPECTED_INSTALL_DIR/metadata.json"
KUBECONFIG_FILE="$EXPECTED_INSTALL_DIR/auth/kubeconfig"
STATE_DIR="$HOME/.config/openshift-upi-lab"
RECOVERY_FILE="$STATE_DIR/worker-reboot-recovery.json"
HAPROXY_RECOVERY_FILE="$STATE_DIR/haproxy-failover-recovery.json"
HAPROXY_LOCK_FILE="$STATE_DIR/haproxy-failover.lock"
LOCK_FILE="$STATE_DIR/worker-reboot.lock"
RESULT_DIR="$STATE_DIR/worker-reboot-results"
PREFLIGHT_ONLY=false
RECOVERY_MODE=false
TARGET_NAME=

usage() {
  cat <<'EOF'
Usage:
  bash scripts/34-test-worker-reboot.sh --preflight-only worker-0
  bash scripts/34-test-worker-reboot.sh worker-0
  bash scripts/34-test-worker-reboot.sh --recover

Run one planned worker reboot at a time in this fixed order:
  worker-0 -> worker-2 -> worker-1

This script never uses --force or --disable-eviction and never tests a
control-plane node.
EOF
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --preflight-only)
      "$RECOVERY_MODE" && error '--preflight-only and --recover cannot be combined.'
      PREFLIGHT_ONLY=true
      ;;
    --recover)
      "$PREFLIGHT_ONLY" && error '--preflight-only and --recover cannot be combined.'
      RECOVERY_MODE=true
      ;;
    worker-0 | worker-1 | worker-2)
      [[ -z "$TARGET_NAME" ]] || error 'Specify exactly one worker target.'
      TARGET_NAME="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      error "Unknown argument: $1"
      ;;
  esac
  shift
done

if "$RECOVERY_MODE"; then
  [[ -z "$TARGET_NAME" ]] \
    || error '--recover reads the target from the recovery marker; do not specify a target.'
else
  [[ "$TARGET_NAME" == worker-0 || "$TARGET_NAME" == worker-1 || "$TARGET_NAME" == worker-2 ]] || {
    usage >&2
    error 'Specify worker-0, worker-1, or worker-2.'
  }
fi

for command_name in aws curl flock jq oc terraform; do
  phase6_require_command "$command_name"
done
[[ "$AWS_REGION_NAME" == "$EXPECTED_AWS_REGION" ]] \
  || error "AWS_REGION_NAME must be $EXPECTED_AWS_REGION for this lab."
[[ "$TERRAFORM_DIR" == "$EXPECTED_TERRAFORM_DIR" ]] \
  || error "TERRAFORM_DIR must be $EXPECTED_TERRAFORM_DIR for this test."
[[ "$INSTALL_DIR" == "$EXPECTED_INSTALL_DIR" ]] \
  || error "INSTALL_DIR must be $EXPECTED_INSTALL_DIR for this test."
[[ "$PHASE7_EXPECTED_API_SERVER" == "$EXPECTED_API_SERVER" ]] \
  || error "PHASE7_EXPECTED_API_SERVER must be $EXPECTED_API_SERVER for this test."
[[ "$PHASE7_METADATA_FILE" == "$EXPECTED_METADATA_FILE" ]] \
  || error "PHASE7_METADATA_FILE must be $EXPECTED_METADATA_FILE for this test."

phase6_require_file "$INSTALL_DIR/install-complete.ok"
phase6_require_file "$KUBECONFIG_FILE"
phase6_require_file "$EXPECTED_METADATA_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

install -d -m 700 "$STATE_DIR" "$RESULT_DIR"
chmod 700 "$STATE_DIR" "$RESULT_DIR"
exec 8>"$HAPROXY_LOCK_FILE"
flock -n 8 || error "A HAProxy failure test or recovery is active: $HAPROXY_LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || error "Another worker reboot test or recovery is active: $LOCK_FILE"

[[ ! -e "$HAPROXY_RECOVERY_FILE" ]] \
  || error "An unfinished HAProxy recovery exists. Run scripts/33-test-haproxy-failover.sh --recover first."

configured_region="$(aws configure get region --profile "$AWS_PROFILE_NAME" 2>/dev/null || true)"
[[ "$configured_region" == "$EXPECTED_AWS_REGION" ]] \
  || error "AWS profile $AWS_PROFILE_NAME must use region $EXPECTED_AWS_REGION; found ${configured_region:-unset}."

aws_account="$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE_NAME" --query Account --output text)"
terraform_outputs_json="$(terraform -chdir="$TERRAFORM_DIR" output -json)"
terraform_account="$(jq -er '.account_id.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no account_id.'
[[ "$aws_account" =~ ^[0-9]{12}$ && "$aws_account" == "$terraform_account" ]] \
  || error "AWS account $aws_account does not match Terraform account $terraform_account."

terraform_workspace="$(terraform -chdir="$TERRAFORM_DIR" workspace show)"
[[ "$terraform_workspace" == default ]] \
  || error "Terraform workspace must be default; found $terraform_workspace."
terraform_state_json="$(terraform -chdir="$TERRAFORM_DIR" state pull)" \
  || error 'Unable to read the Terraform state metadata.'
terraform_lineage="$(jq -er '.lineage' <<<"$terraform_state_json")" \
  || error 'Terraform state has no valid lineage.'
terraform_serial="$(jq -er '.serial' <<<"$terraform_state_json")" \
  || error 'Terraform state has no valid serial.'
[[ "$terraform_lineage" =~ ^[0-9a-f-]{36}$ && "$terraform_serial" =~ ^[0-9]+$ ]] \
  || error 'Terraform state lineage or serial is invalid.'

vpc_id="$(jq -er '.vpc_id.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no vpc_id.'
[[ "$vpc_id" =~ ^vpc-[0-9a-f]+$ ]] || error 'Terraform output vpc_id is invalid.'

instances_json="$(jq -ec '.openshift_instances.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no openshift_instances map.'
jq -e '
  (keys | sort) == ([
    "control-plane-0", "control-plane-1", "control-plane-2",
    "worker-0", "worker-1", "worker-2"
  ] | sort) and
  all(to_entries[];
    (.value.id | test("^i-[0-9a-f]+$")) and
    (.value.private_ip | test("^10\\.80\\.(10|20|30)\\.(10|20)$")) and
    (.value.role == "control-plane" or .value.role == "worker"))
' <<<"$instances_json" >/dev/null \
  || error 'Terraform must manage exactly three control-plane and three worker instances.'

declare -A EXPECTED_IPS=(
  [control-plane-0]=10.80.10.10
  [control-plane-1]=10.80.20.10
  [control-plane-2]=10.80.30.10
  [worker-0]=10.80.10.20
  [worker-1]=10.80.20.20
  [worker-2]=10.80.30.20
)
NODE_NAMES=(control-plane-0 control-plane-1 control-plane-2 worker-0 worker-1 worker-2)
declare -A INSTANCE_IDS=()
declare -A INSTANCE_IPS=()
declare -A INSTANCE_SUBNETS=()
for node_short_name in "${NODE_NAMES[@]}"; do
  INSTANCE_IDS["$node_short_name"]="$(jq -er --arg name "$node_short_name" '.[$name].id' <<<"$instances_json")" \
    || error "Terraform output has no instance ID for $node_short_name."
  INSTANCE_IPS["$node_short_name"]="$(jq -er --arg name "$node_short_name" '.[$name].private_ip' <<<"$instances_json")" \
    || error "Terraform output has no private IP for $node_short_name."
  INSTANCE_SUBNETS["$node_short_name"]="$(jq -er --arg name "$node_short_name" '.[$name].subnet_id' <<<"$instances_json")" \
    || error "Terraform output has no subnet ID for $node_short_name."
  [[ "${INSTANCE_IPS[$node_short_name]}" == "${EXPECTED_IPS[$node_short_name]}" ]] \
    || error "Terraform returned an unexpected private IP for $node_short_name."
  [[ "${INSTANCE_SUBNETS[$node_short_name]}" =~ ^subnet-[0-9a-f]+$ ]] \
    || error "Terraform returned an invalid subnet ID for $node_short_name."
done
rhcos_ami_id="$(jq -er '.rhcos_ami.value.id' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no RHCOS AMI ID.'
[[ "$rhcos_ami_id" =~ ^ami-[0-9a-f]+$ ]] || error 'Terraform returned an invalid RHCOS AMI ID.'

mapfile -t ALL_INSTANCE_IDS < <(for node_short_name in "${NODE_NAMES[@]}"; do
  printf '%s\n' "${INSTANCE_IDS[$node_short_name]}"
done)

describe_all_instances() {
  aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "${ALL_INSTANCE_IDS[@]}" --output json
}

assert_all_ec2_instances_ready() {
  local instances_status_json instance_status_json
  instances_status_json="$(describe_all_instances)" || return 1
  jq -e --argjson expected_ids "$(printf '%s\n' "${ALL_INSTANCE_IDS[@]}" | jq -R . | jq -s 'sort')" '
    [.Reservations[].Instances[]] as $instances |
    ($instances | length) == 6 and
    ([$instances[].InstanceId] | sort) == $expected_ids and
    all($instances[];
      .State.Name == "running" and
      (.PublicIpAddress // "") == "")
  ' <<<"$instances_status_json" >/dev/null || return 1

  instance_status_json="$(aws ec2 describe-instance-status \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --include-all-instances --instance-ids "${ALL_INSTANCE_IDS[@]}" --output json)" \
    || return 1
  jq -e --argjson expected_ids "$(printf '%s\n' "${ALL_INSTANCE_IDS[@]}" | jq -R . | jq -s 'sort')" '
    .InstanceStatuses as $statuses |
    ($statuses | length) == 6 and
    ([$statuses[].InstanceId] | sort) == $expected_ids and
    all($statuses[];
      .InstanceState.Name == "running" and
      .InstanceStatus.Status == "ok" and
      .SystemStatus.Status == "ok")
  ' <<<"$instance_status_json" >/dev/null
}

assert_target_aws_binding() {
  local target_name="$1" target_id="$2" target_ip="$3" instance_json target_subnet
  target_subnet="${INSTANCE_SUBNETS[$target_name]}"
  instance_json="$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" --output json)" || return 1
  jq -e \
    --arg id "$target_id" --arg ip "$target_ip" --arg vpc "$vpc_id" \
    --arg subnet "$target_subnet" --arg ami "$rhcos_ami_id" \
    --arg name "openshift-upi-lab-$target_name" '
    def tag($instance; $key):
      ([$instance.Tags[]? | select(.Key == $key) | .Value][0] // "");
    [.Reservations[].Instances[]] as $instances |
    ($instances | length) == 1 and
    ($instances[0] |
      .InstanceId == $id and
      .PrivateIpAddress == $ip and
      .VpcId == $vpc and
      .SubnetId == $subnet and
      .ImageId == $ami and
      (.PublicIpAddress // "") == "" and
      tag(.; "Name") == $name and
      tag(.; "Role") == "worker" and
      tag(.; "Project") == "openshift-upi-lab")
  ' <<<"$instance_json" >/dev/null
}

assert_target_aws_identity() {
  local target_name="$1" target_id="$2" target_ip="$3" instance_state
  assert_target_aws_binding "$target_name" "$target_id" "$target_ip" || return 1
  instance_state="$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)" || return 1
  [[ "$instance_state" == running ]]
}

assert_target_instance_status_ok() {
  local target_id="$1" status_json
  status_json="$(aws ec2 describe-instance-status \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --include-all-instances --instance-ids "$target_id" --output json)" || return 1
  jq -e --arg id "$target_id" '
    (.InstanceStatuses | length) == 1 and
    .InstanceStatuses[0].InstanceId == $id and
    .InstanceStatuses[0].InstanceState.Name == "running" and
    .InstanceStatuses[0].InstanceStatus.Status == "ok" and
    .InstanceStatuses[0].SystemStatus.Status == "ok"
  ' <<<"$status_json" >/dev/null
}

assert_six_nodes_ready() {
  local nodes_json
  nodes_json="$(oc get nodes -o json)" || return 1
  jq -e '
    (.items | length) == 6 and
    all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"$nodes_json" >/dev/null
}

assert_six_nodes_ready_and_schedulable() {
  local nodes_json
  nodes_json="$(oc get nodes -o json)" || return 1
  jq -e '
    (.items | length) == 6 and
    all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      ((.spec.unschedulable // false) == false))
  ' <<<"$nodes_json" >/dev/null
}

assert_six_nodes_ready_with_only_target_unschedulable() {
  local node_name="$1" nodes_json
  nodes_json="$(oc get nodes -o json)" || return 1
  jq -e --arg node_name "$node_name" '
    (.items | length) == 6 and
    all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True")) and
    ([.items[] |
      select((.spec.unschedulable // false) == true) |
      .metadata.name] == [$node_name])
  ' <<<"$nodes_json" >/dev/null
}

assert_target_node_identity() {
  local target_name="$1" target_id="$2" target_ip="$3" expected_uid="${4:-}" node_name node_json
  node_name="$target_name.ocp.lab.k8study.com"
  node_json="$(oc get node "$node_name" -o json)" || return 1
  jq -e --arg name "$node_name" --arg ip "$target_ip" '
    .metadata.name == $name and
    .metadata.labels["node-role.kubernetes.io/worker"] == "" and
    (.metadata.labels["node-role.kubernetes.io/master"] // null) == null and
    (.metadata.labels["node-role.kubernetes.io/control-plane"] // null) == null and
    any(.status.addresses[]?; .type == "InternalIP" and .address == $ip) and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] | length > 0) and
    .metadata.annotations["machineconfiguration.openshift.io/currentConfig"] ==
      .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] and
    .metadata.annotations["machineconfiguration.openshift.io/state"] == "Done"
  ' <<<"$node_json" >/dev/null || return 1

  if [[ -n "$expected_uid" ]]; then
    [[ "$(jq -r '.metadata.uid' <<<"$node_json")" == "$expected_uid" ]] || return 1
  fi

  local provider_id
  provider_id="$(jq -r '.spec.providerID // ""' <<<"$node_json")"
  [[ -z "$provider_id" || "$provider_id" == *"/$target_id" ]] || return 1
}

assert_machine_config_pools_stable() {
  local mcp_json
  mcp_json="$(oc get machineconfigpools -o json)" || return 1
  jq -e '
    def condition_is($pool; $type; $status):
      any($pool.status.conditions[]?; .type == $type and .status == $status);
    def stable($pool; $count):
      $pool.spec.paused != true and
      $pool.status.machineCount == $count and
      $pool.status.readyMachineCount == $count and
      $pool.status.updatedMachineCount == $count and
      ($pool.status.unavailableMachineCount // 0) == 0 and
      ($pool.status.degradedMachineCount // 0) == 0 and
      condition_is($pool; "Updated"; "True") and
      condition_is($pool; "Updating"; "False") and
      condition_is($pool; "Degraded"; "False");
    [.items[] | select(.metadata.name == "master")][0] as $master |
    [.items[] | select(.metadata.name == "worker")][0] as $worker |
    (.items | length) == 2 and stable($master; 3) and stable($worker; 3)
  ' <<<"$mcp_json" >/dev/null
}

# A manually cordoned Ready worker is reported by the Machine Config Operator as
# one unavailable machine even after its rendered configuration has converged.
# Accept only that exact, non-degraded maintenance state before uncordon. The
# normal strict 3/3 MCP check is still required after uncordon.
assert_machine_config_pools_safe_before_uncordon() {
  local node_name="$1" mcp_json

  if ! node_is_unschedulable "$node_name"; then
    assert_six_nodes_ready_and_schedulable \
      && assert_machine_config_pools_stable
    return
  fi

  assert_six_nodes_ready_with_only_target_unschedulable "$node_name" \
    || return 1

  mcp_json="$(oc get machineconfigpools -o json)" || return 1
  jq -e '
    def condition_is($pool; $type; $status):
      any($pool.status.conditions[]?; .type == $type and .status == $status);
    def stable($pool; $count):
      $pool.spec.paused != true and
      $pool.status.machineCount == $count and
      $pool.status.readyMachineCount == $count and
      $pool.status.updatedMachineCount == $count and
      ($pool.status.unavailableMachineCount // 0) == 0 and
      ($pool.status.degradedMachineCount // 0) == 0 and
      condition_is($pool; "Updated"; "True") and
      condition_is($pool; "Updating"; "False") and
      condition_is($pool; "Degraded"; "False");
    def expected_cordoned_worker($pool):
      $pool.spec.paused != true and
      $pool.status.machineCount == 3 and
      $pool.status.readyMachineCount == 2 and
      $pool.status.updatedMachineCount == 3 and
      ($pool.status.unavailableMachineCount // 0) == 1 and
      ($pool.status.degradedMachineCount // 0) == 0 and
      condition_is($pool; "Updated"; "False") and
      condition_is($pool; "Updating"; "True") and
      condition_is($pool; "Degraded"; "False");
    [.items[] | select(.metadata.name == "master")][0] as $master |
    [.items[] | select(.metadata.name == "worker")][0] as $worker |
    (.items | length) == 2 and
    stable($master; 3) and
    (stable($worker; 3) or expected_cordoned_worker($worker))
  ' <<<"$mcp_json" >/dev/null
}

assert_cluster_operators_stable() {
  local operators_json
  operators_json="$(oc get clusteroperators -o json)" || return 1
  jq -e '
    (.items | length) > 0 and all(.items[];
      any(.status.conditions[]?; .type == "Available" and .status == "True") and
      any(.status.conditions[]?; .type == "Progressing" and .status == "False") and
      any(.status.conditions[]?; .type == "Degraded" and .status == "False"))
  ' <<<"$operators_json" >/dev/null
}

assert_cluster_version_available() {
  oc get clusterversion version -o json | jq -e '
    any(.status.conditions[]?; .type == "Available" and .status == "True")
  ' >/dev/null
}

assert_no_pending_csrs() {
  local csr_json
  csr_json="$(oc get csr -o json)" || return 1
  jq -e '[.items[] | select((.status.conditions // []) | length == 0)] | length == 0' \
    <<<"$csr_json" >/dev/null
}

assert_storage_ready() {
  local deployment_json root_pv_json root_pvc_json storage_class_json
  deployment_json="$(oc get deployment nfs-subdir-external-provisioner \
    -n nfs-provisioner -o json)" || return 1
  jq -e '
    .spec.replicas == 1 and
    .status.observedGeneration >= .metadata.generation and
    .status.updatedReplicas == 1 and
    .status.readyReplicas == 1 and
    .status.availableReplicas == 1 and
    (.status.unavailableReplicas // 0) == 0
  ' <<<"$deployment_json" >/dev/null || return 1

  root_pv_json="$(oc get persistentvolume nfs-subdir-provisioner-root -o json)" || return 1
  root_pvc_json="$(oc get persistentvolumeclaim nfs-subdir-provisioner-root \
    -n nfs-provisioner -o json)" || return 1
  storage_class_json="$(oc get storageclass nfs-rwx -o json)" || return 1
  jq -e '
    .status.phase == "Bound" and
    .spec.persistentVolumeReclaimPolicy == "Retain" and
    .spec.nfs.server == "10.80.40.41" and
    .spec.nfs.path == "/srv/nfs/openshift"
  ' <<<"$root_pv_json" >/dev/null || return 1
  jq -e '.status.phase == "Bound" and .spec.volumeName == "nfs-subdir-provisioner-root"' \
    <<<"$root_pvc_json" >/dev/null || return 1
  jq -e '
    .provisioner == "lab.k8study.com/nfs-subdir-external-provisioner" and
    .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "false"
  ' <<<"$storage_class_json" >/dev/null
}

assert_ingress_ready() {
  local deployment_json
  deployment_json="$(oc get deployment router-default -n openshift-ingress -o json)" || return 1
  jq -e '
    .spec.replicas == 2 and
    .status.observedGeneration >= .metadata.generation and
    .status.updatedReplicas == 2 and
    .status.readyReplicas == 2 and
    .status.availableReplicas == 2 and
    (.status.unavailableReplicas // 0) == 0
  ' <<<"$deployment_json" >/dev/null
}

assert_ready_workload_pods_avoid_node() {
  local excluded_node="$1" router_pods_json nfs_pods_json

  router_pods_json="$(oc get pods -n openshift-ingress \
    -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
    -o json)" || return 1
  jq -e --arg excluded "$excluded_node" '
    [.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] as $pods |
    ($pods | length) == 2 and
    ([$pods[].spec.nodeName] | unique | length) == 2 and
    ($excluded == "" or all($pods[]; .spec.nodeName != $excluded))
  ' <<<"$router_pods_json" >/dev/null || return 1

  nfs_pods_json="$(oc get pods -n nfs-provisioner \
    -l app.kubernetes.io/name=nfs-subdir-external-provisioner -o json)" || return 1
  jq -e --arg excluded "$excluded_node" '
    [.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] as $pods |
    ($pods | length) == 1 and
    ($excluded == "" or all($pods[]; .spec.nodeName != $excluded))
  ' <<<"$nfs_pods_json" >/dev/null
}

wait_for_workloads_ready() {
  local excluded_node="${1:-}" attempt
  oc rollout status deployment/router-default \
    -n openshift-ingress --timeout=10m || return 1
  oc rollout status deployment/nfs-subdir-external-provisioner \
    -n nfs-provisioner --timeout=10m || return 1
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if assert_ingress_ready \
      && assert_storage_ready \
      && assert_ready_workload_pods_avoid_node "$excluded_node"; then
      return 0
    fi
    ((attempt % 6 == 0)) \
      && printf 'Waiting for Router and NFS workload placement to converge (%ds elapsed).\n' "$((attempt * 5))"
    sleep 5
  done
  printf 'ERROR: Router or NFS workload placement did not converge.\n' >&2
  if [[ -n "$excluded_node" ]]; then
    oc get pods -A -o wide --field-selector "spec.nodeName=$excluded_node" >&2 || true
  fi
  return 1
}

assert_api_and_console_reachable() {
  local console_host
  curl --fail --silent --show-error --insecure \
    --connect-timeout 5 --max-time 10 \
    https://api.ocp.lab.k8study.com:6443/readyz >/dev/null || return 1
  console_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')" \
    || return 1
  [[ "$console_host" == console-openshift-console.apps.ocp.lab.k8study.com ]] \
    || return 1
  curl --fail --silent --show-error --insecure --head \
    --connect-timeout 5 --max-time 10 "https://$console_host" >/dev/null
}

assert_reboot_permission() {
  local target_id="$1" dry_run_output dry_run_status
  set +e
  dry_run_output="$(aws ec2 reboot-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" --dry-run --no-cli-pager 2>&1)"
  dry_run_status=$?
  set -e
  [[ "$dry_run_status" -ne 0 && "$dry_run_output" == *DryRunOperation* ]]
}

wait_for_platform_stable() {
  local attempt pending_count
  for ((attempt = 1; attempt <= 180; attempt++)); do
    pending_count="$(oc get csr -o json 2>/dev/null | jq -r \
      '[.items[] | select((.status.conditions // []) | length == 0)] | length' 2>/dev/null || printf 'unknown')"
    if [[ "$pending_count" != 0 ]]; then
      printf 'ERROR: Pending CSR count is %s; do not auto-approve it.\n' "$pending_count" >&2
      printf 'Review it with: bash scripts/27-review-csrs.sh\n' >&2
      return 1
    fi
    if assert_machine_config_pools_stable \
      && assert_cluster_version_available \
      && assert_cluster_operators_stable; then
      return 0
    fi
    ((attempt % 6 == 0)) \
      && printf 'Waiting for MCP, ClusterVersion, and ClusterOperators to stabilize (%ds elapsed).\n' "$((attempt * 5))"
    sleep 5
  done
  printf 'ERROR: The strict post-uncordon platform state did not converge.\n' >&2
  oc get machineconfigpools worker master >&2 || true
  return 1
}

wait_for_platform_safe_before_uncordon() {
  local node_name="$1" attempt pending_count
  for ((attempt = 1; attempt <= 180; attempt++)); do
    pending_count="$(oc get csr -o json 2>/dev/null | jq -r \
      '[.items[] | select((.status.conditions // []) | length == 0)] | length' 2>/dev/null || printf 'unknown')"
    if [[ "$pending_count" != 0 ]]; then
      printf 'ERROR: Pending CSR count is %s; do not auto-approve it.\n' "$pending_count" >&2
      printf 'Review it with: bash scripts/27-review-csrs.sh\n' >&2
      return 1
    fi
    if assert_machine_config_pools_safe_before_uncordon "$node_name" \
      && assert_cluster_version_available \
      && assert_cluster_operators_stable; then
      return 0
    fi
    ((attempt % 6 == 0)) \
      && printf 'Waiting for the safe pre-uncordon MCP and platform state (%ds elapsed).\n' "$((attempt * 5))"
    sleep 5
  done
  printf 'ERROR: The pre-uncordon platform state did not converge.\n' >&2
  oc get node "$node_name" >&2 || true
  oc get machineconfigpools worker master >&2 || true
  return 1
}

get_node_uid() {
  oc get node "$1" -o jsonpath='{.metadata.uid}'
}

get_node_boot_id() {
  oc get node "$1" -o jsonpath='{.status.nodeInfo.bootID}'
}

node_is_ready() {
  oc get node "$1" -o json | jq -e '
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' >/dev/null
}

node_is_unschedulable() {
  [[ "$(oc get node "$1" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)" == true ]]
}

wait_for_node_ready() {
  local node_name="$1" attempt
  for ((attempt = 1; attempt <= 240; attempt++)); do
    if node_is_ready "$node_name" 2>/dev/null; then
      return 0
    fi
    ((attempt % 12 == 0)) \
      && printf 'Waiting for %s to become Ready (%ds elapsed).\n' "$node_name" "$((attempt * 5))"
    sleep 5
  done
  return 1
}

wait_for_target_node_converged() {
  local target_name="$1" target_id="$2" target_ip="$3" expected_uid="$4" attempt
  for ((attempt = 1; attempt <= 180; attempt++)); do
    if [[ "$(get_node_uid "$target_name.ocp.lab.k8study.com" 2>/dev/null || true)" != "$expected_uid" ]]; then
      printf 'ERROR: Node UID changed while waiting for MCO convergence.\n' >&2
      return 1
    fi
    if assert_target_node_identity "$target_name" "$target_id" "$target_ip" "$expected_uid"; then
      return 0
    fi
    ((attempt % 12 == 0)) \
      && printf 'Waiting for %s Node and MCO state to converge (%ds elapsed).\n' "$target_name" "$((attempt * 5))"
    sleep 5
  done
  return 1
}

wait_for_boot_id_change() {
  local node_name="$1" old_boot_id="$2" expected_uid="$3" attempt current_uid current_boot_id
  for ((attempt = 1; attempt <= 240; attempt++)); do
    current_uid="$(get_node_uid "$node_name" 2>/dev/null || true)"
    current_boot_id="$(get_node_boot_id "$node_name" 2>/dev/null || true)"
    if [[ -n "$current_uid" && "$current_uid" != "$expected_uid" ]]; then
      printf 'ERROR: Node UID changed while waiting for the reboot.\n' >&2
      return 1
    fi
    if [[ "$current_boot_id" =~ ^[0-9a-f-]{36}$ && "$current_boot_id" != "$old_boot_id" ]]; then
      printf '%s' "$current_boot_id"
      return 0
    fi
    ((attempt % 12 == 0)) \
      && printf 'Waiting for %s bootID to change (%ds elapsed).\n' "$node_name" "$((attempt * 5))" >&2
    sleep 5
  done
  return 1
}

wait_for_stability_window() {
  local success_streak=0 attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if assert_six_nodes_ready_and_schedulable \
      && assert_machine_config_pools_stable \
      && assert_cluster_version_available \
      && assert_cluster_operators_stable \
      && assert_no_pending_csrs \
      && assert_ingress_ready \
      && assert_storage_ready; then
      success_streak=$((success_streak + 1))
      printf 'Stable recovery sample %d/3 passed.\n' "$success_streak"
      ((success_streak == 3)) && return 0
    else
      success_streak=0
      printf 'Recovery is not yet fully stable; retrying (%d/30).\n' "$attempt" >&2
    fi
    ((attempt < 30)) && sleep 30
  done
  return 1
}

result_file_for() {
  printf '%s/%s-%s.json' "$RESULT_DIR" "$cluster_id" "$1"
}

assert_result_exists() {
  local completed_target="$1" result_file completed_id completed_node_name completed_node_uid
  result_file="$(result_file_for "$completed_target")"
  completed_id="${INSTANCE_IDS[$completed_target]}"
  completed_node_name="$completed_target.ocp.lab.k8study.com"
  completed_node_uid="$(get_node_uid "$completed_node_name" 2>/dev/null || true)"
  [[ "$completed_node_uid" =~ ^[0-9a-f-]{36}$ ]] || return 1
  [[ -s "$result_file" ]] || return 1
  jq -e \
    --arg cluster_id "$cluster_id" \
    --arg target "$completed_target" \
    --arg instance_id "$completed_id" \
    --arg node_name "$completed_node_name" \
    --arg node_uid "$completed_node_uid" '
    .cluster_id == $cluster_id and
    .target_name == $target and
    .target_instance_id == $instance_id and
    .node_name == $node_name and
    .node_uid == $node_uid and
    (.boot_id_before | test("^[0-9a-f-]{36}$")) and
    (.boot_id_after | test("^[0-9a-f-]{36}$")) and
    .boot_id_before != .boot_id_after
  ' "$result_file" >/dev/null
}

assert_test_order() {
  local target_name="$1"
  if assert_result_exists "$target_name"; then
    printf 'ERROR: %s already passed for this cluster and instance ID.\n' "$target_name" >&2
    return 1
  fi
  case "$target_name" in
    worker-0)
      ;;
    worker-2)
      assert_result_exists worker-0 || {
        printf 'ERROR: Complete worker-0 first for this cluster.\n' >&2
        return 1
      }
      ;;
    worker-1)
      assert_result_exists worker-0 || {
        printf 'ERROR: Complete worker-0 first for this cluster.\n' >&2
        return 1
      }
      assert_result_exists worker-2 || {
        printf 'ERROR: Complete worker-2 before worker-1 for this cluster.\n' >&2
        return 1
      }
      ;;
  esac
}

write_result() {
  local target_name="$1" target_id="$2" node_name="$3" node_uid="$4"
  local boot_id_before="$5" boot_id_after="$6" result_file temp_file
  result_file="$(result_file_for "$target_name")"
  temp_file="$(mktemp "$RESULT_DIR/.worker-reboot-result.XXXXXX")" || return 1
  chmod 600 "$temp_file" || return 1
  jq -n \
    --arg cluster_id "$cluster_id" \
    --arg target_name "$target_name" \
    --arg target_instance_id "$target_id" \
    --arg node_name "$node_name" \
    --arg node_uid "$node_uid" \
    --arg boot_id_before "$boot_id_before" \
    --arg boot_id_after "$boot_id_after" \
    --arg completed_at "$(date --iso-8601=seconds)" '
    {
      cluster_id: $cluster_id,
      target_name: $target_name,
      target_instance_id: $target_instance_id,
      node_name: $node_name,
      node_uid: $node_uid,
      boot_id_before: $boot_id_before,
      boot_id_after: $boot_id_after,
      completed_at: $completed_at
    }
  ' >"$temp_file" || return 1
  mv -- "$temp_file" "$result_file" || return 1
}

write_recovery_marker() {
  local target_name="$1" target_id="$2" target_ip="$3" node_name="$4"
  local node_uid="$5" boot_id_before="$6" temp_file
  temp_file="$(mktemp "$STATE_DIR/.worker-reboot-recovery.XXXXXX")"
  chmod 600 "$temp_file"
  jq -n \
    --arg account_id "$aws_account" \
    --arg region "$AWS_REGION_NAME" \
    --arg workspace "$terraform_workspace" \
    --arg terraform_lineage "$terraform_lineage" \
    --argjson terraform_serial "$terraform_serial" \
    --arg cluster_id "$cluster_id" \
    --arg target_name "$target_name" \
    --arg target_instance_id "$target_id" \
    --arg target_private_ip "$target_ip" \
    --arg node_name "$node_name" \
    --arg node_uid "$node_uid" \
    --arg boot_id_before "$boot_id_before" \
    --arg created_at "$(date --iso-8601=seconds)" '
    {
      account_id: $account_id,
      region: $region,
      terraform_workspace: $workspace,
      terraform_lineage: $terraform_lineage,
      terraform_serial: $terraform_serial,
      cluster_id: $cluster_id,
      target_name: $target_name,
      target_instance_id: $target_instance_id,
      target_private_ip: $target_private_ip,
      node_name: $node_name,
      node_uid: $node_uid,
      boot_id_before: $boot_id_before,
      boot_id_after: null,
      originally_unschedulable: false,
      reboot_may_have_been_requested: false,
      stage: "armed",
      created_at: $created_at,
      updated_at: $created_at
    }
  ' >"$temp_file"
  mv -- "$temp_file" "$RECOVERY_FILE"
}

update_recovery_marker() {
  local stage="$1" reboot_may_have_been_requested="$2" boot_id_after="${3:-}"
  local temp_file
  temp_file="$(mktemp "$STATE_DIR/.worker-reboot-recovery.XXXXXX")" || return 1
  chmod 600 "$temp_file" || return 1
  jq \
    --arg stage "$stage" \
    --argjson reboot_requested "$reboot_may_have_been_requested" \
    --arg boot_id_after "$boot_id_after" \
    --arg updated_at "$(date --iso-8601=seconds)" '
    .stage = $stage |
    .reboot_may_have_been_requested = $reboot_requested |
    .boot_id_after = (if $boot_id_after == "" then .boot_id_after else $boot_id_after end) |
    .updated_at = $updated_at
  ' "$RECOVERY_FILE" >"$temp_file" || return 1
  mv -- "$temp_file" "$RECOVERY_FILE" || return 1
}

print_recovery_notice() {
  printf 'Recovery marker: %s\n' "$RECOVERY_FILE" >&2
  if [[ -s "$RECOVERY_FILE" ]]; then
    jq -r '"Recorded target: \(.target_name) (\(.target_instance_id)); stage=\(.stage); created=\(.created_at)"' \
      "$RECOVERY_FILE" >&2 || true
  fi
  printf 'Run this command before starting another test:\n' >&2
  printf '  bash scripts/34-test-worker-reboot.sh --recover\n' >&2
}

ensure_target_instance_running() {
  local target_name="$1" target_id="$2" instance_state
  RECOVERY_INSTANCE_STARTED=false
  assert_target_aws_binding "$target_name" "$target_id" "${INSTANCE_IPS[$target_name]}" \
    || return 1
  instance_state="$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)" || return 1
  case "$instance_state" in
    stopped)
      printf 'Starting unexpectedly stopped %s (%s).\n' "$target_name" "$target_id"
      update_recovery_marker recovery-starting true || return 1
      aws ec2 start-instances \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" --no-cli-pager >/dev/null || return 1
      RECOVERY_INSTANCE_STARTED=true
      ;;
    stopping)
      aws ec2 wait instance-stopped \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" || return 1
      update_recovery_marker recovery-starting true || return 1
      aws ec2 start-instances \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" --no-cli-pager >/dev/null || return 1
      RECOVERY_INSTANCE_STARTED=true
      ;;
    pending | running)
      ;;
    *)
      printf 'ERROR: Cannot recover %s from EC2 state %s.\n' "$target_name" "$instance_state" >&2
      return 1
      ;;
  esac
  aws ec2 wait instance-running \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" || return 1
}

recover_target() {
  local target_name="$1" target_id="$2" target_ip="$3" node_name="$4"
  local expected_uid="$5" boot_id_before="$6" reboot_requested="$7"
  local boot_id_after current_boot_id boot_change_expected="$reboot_requested"

  ensure_target_instance_running "$target_name" "$target_id" || return 1
  if [[ "$RECOVERY_INSTANCE_STARTED" == true ]]; then
    boot_change_expected=true
  fi

  if [[ "$boot_change_expected" == true ]]; then
    printf 'Waiting for the recorded reboot of %s to be observed.\n' "$target_name"
    boot_id_after="$(wait_for_boot_id_change "$node_name" "$boot_id_before" "$expected_uid")" \
      || return 1
    update_recovery_marker boot-observed true "$boot_id_after" || return 1
    printf 'PASS: %s bootID changed from %s to %s.\n' \
      "$target_name" "$boot_id_before" "$boot_id_after"
  else
    current_boot_id="$(get_node_boot_id "$node_name" 2>/dev/null || true)"
    [[ "$current_boot_id" == "$boot_id_before" ]] || {
      printf 'ERROR: bootID changed even though no reboot request was recorded.\n' >&2
      return 1
    }
    boot_id_after=
  fi

  wait_for_node_ready "$node_name" || return 1
  aws ec2 wait instance-status-ok \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" || return 1
  assert_target_aws_identity "$target_name" "$target_id" "$target_ip" || return 1
  assert_target_instance_status_ok "$target_id" || return 1
  wait_for_target_node_converged "$target_name" "$target_id" "$target_ip" "$expected_uid" || return 1
  wait_for_platform_safe_before_uncordon "$node_name" || return 1
  assert_no_pending_csrs || return 1

  if node_is_unschedulable "$node_name"; then
    oc adm uncordon "$node_name" || return 1
  fi
  update_recovery_marker uncordoned "$boot_change_expected" "$boot_id_after" || return 1

  wait_for_workloads_ready || return 1
  assert_api_and_console_reachable || return 1
  wait_for_stability_window || return 1
  bash "$SCRIPT_DIR/29-validate-openshift-cluster.sh" || return 1
  rm -f -- "$RECOVERY_FILE" || return 1
  printf 'PASS: %s recovery completed and the recovery marker was removed.\n' "$target_name"
  printf 'Recovery restored availability but did not record this interrupted test as passed.\n'
}

phase7_assert_target_cluster "$KUBECONFIG_FILE"
cluster_id="$(oc get clusterversion version -o jsonpath='{.spec.clusterID}')"
[[ "$cluster_id" =~ ^[0-9a-f-]{36}$ ]] || error 'The active cluster ID is invalid.'

if [[ -e "$RECOVERY_FILE" ]]; then
  [[ -s "$RECOVERY_FILE" ]] || error "Recovery marker exists but is empty: $RECOVERY_FILE"
  if ! "$RECOVERY_MODE"; then
    print_recovery_notice
    error 'An unfinished worker reboot recovery exists; refusing to start another test.'
  fi

  marker_account="$(jq -er '.account_id' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid account_id.'
  marker_region="$(jq -er '.region' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid region.'
  marker_workspace="$(jq -er '.terraform_workspace' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid terraform_workspace.'
  marker_lineage="$(jq -er '.terraform_lineage' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid terraform_lineage.'
  marker_serial="$(jq -er '.terraform_serial' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid terraform_serial.'
  marker_cluster_id="$(jq -er '.cluster_id' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid cluster_id.'
  marker_target_name="$(jq -er '.target_name' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid target_name.'
  marker_target_id="$(jq -er '.target_instance_id' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid target_instance_id.'
  marker_target_ip="$(jq -er '.target_private_ip' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid target_private_ip.'
  marker_node_name="$(jq -er '.node_name' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid node_name.'
  marker_node_uid="$(jq -er '.node_uid' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid node_uid.'
  marker_boot_id_before="$(jq -er '.boot_id_before' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid boot_id_before.'
  jq -e '
    (.reboot_may_have_been_requested | type) == "boolean" and
    (.originally_unschedulable | type) == "boolean"
  ' "$RECOVERY_FILE" >/dev/null || error 'Recovery marker has invalid boolean fields.'
  marker_reboot_requested="$(jq -r '.reboot_may_have_been_requested' "$RECOVERY_FILE")"
  marker_originally_unschedulable="$(jq -r '.originally_unschedulable' "$RECOVERY_FILE")"

  [[ "$marker_account" == "$aws_account" && "$marker_region" == "$AWS_REGION_NAME" \
      && "$marker_workspace" == "$terraform_workspace" \
      && "$marker_lineage" == "$terraform_lineage" \
      && "$marker_serial" == "$terraform_serial" \
      && "$marker_cluster_id" == "$cluster_id" ]] \
    || error 'Recovery marker account, region, workspace, Terraform state, or cluster does not match the current environment.'
  [[ "$marker_target_name" == worker-0 || "$marker_target_name" == worker-1 \
      || "$marker_target_name" == worker-2 ]] \
    || error 'Recovery marker contains an unexpected worker name.'
  [[ "${INSTANCE_IDS[$marker_target_name]}" == "$marker_target_id" \
      && "${INSTANCE_IPS[$marker_target_name]}" == "$marker_target_ip" \
      && "$marker_node_name" == "$marker_target_name.ocp.lab.k8study.com" ]] \
    || error 'Recovery marker target does not match the current Terraform output.'
  [[ "$marker_originally_unschedulable" == false ]] \
    || error 'This test did not originally own the node scheduling state.'

  printf 'This recovers %s without sending another reboot request.\n' "$marker_target_name"
  read -r -p "Type RECOVER-${marker_target_name^^} to continue: " CONFIRM
  [[ "$CONFIRM" == "RECOVER-${marker_target_name^^}" ]] || {
    printf 'Recovery cancelled. The recovery marker was retained.\n'
    exit 0
  }
  recover_target "$marker_target_name" "$marker_target_id" "$marker_target_ip" \
    "$marker_node_name" "$marker_node_uid" "$marker_boot_id_before" \
    "$marker_reboot_requested" || {
    print_recovery_notice
    error 'Recovery did not complete. The worker remains guarded by the recovery marker.'
  }
  printf 'Worker reboot recovery PASSED.\n'
  exit 0
fi

"$RECOVERY_MODE" && error "No recovery marker exists: $RECOVERY_FILE"

TARGET_ID="${INSTANCE_IDS[$TARGET_NAME]}"
TARGET_IP="${INSTANCE_IPS[$TARGET_NAME]}"
NODE_NAME="$TARGET_NAME.ocp.lab.k8study.com"

assert_test_order "$TARGET_NAME" || error 'Worker reboot order guard failed.'
assert_all_ec2_instances_ready \
  || error 'All six OpenShift EC2 instances must be running with both status checks OK.'
assert_target_aws_identity "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" \
  || error 'The target AWS instance does not match Terraform ID, fixed IP, VPC, or tags.'
assert_reboot_permission "$TARGET_ID" \
  || error 'AWS did not confirm permission to reboot the target instance by dry-run.'
assert_six_nodes_ready_and_schedulable \
  || error 'All six OpenShift nodes must be Ready and schedulable before the test.'
assert_target_node_identity "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" \
  || error 'The target Kubernetes Node does not match the expected worker, IP, or MCO state.'
assert_machine_config_pools_stable \
  || error 'The master and worker MachineConfigPools are not fully stable.'
assert_cluster_version_available \
  || error 'ClusterVersion is not Available.'
assert_cluster_operators_stable \
  || error 'One or more ClusterOperators are not stable.'
assert_no_pending_csrs \
  || error 'A pending CSR exists. Review it with scripts/27-review-csrs.sh.'
wait_for_workloads_ready \
  || error 'Ingress Router or NFS storage is not fully available.'

printf '\nPods currently assigned to %s:\n' "$NODE_NAME"
oc get pods -A --field-selector "spec.nodeName=$NODE_NAME" -o wide

printf '\nChecking drain with server-side dry-run. No node or Pod is changed.\n'
oc adm drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=20m \
  --dry-run=server \
  || error 'Drain dry-run failed. Do not add --force or --disable-eviction.'

printf '\nRunning the full cluster validation before the worker reboot test.\n'
bash "$SCRIPT_DIR/29-validate-openshift-cluster.sh" \
  || error 'The OpenShift cluster baseline validation failed.'

NODE_UID="$(get_node_uid "$NODE_NAME")"
BOOT_ID_BEFORE="$(get_node_boot_id "$NODE_NAME")"
[[ "$NODE_UID" =~ ^[0-9a-f-]{36}$ ]] || error 'The target Node UID is invalid.'
[[ "$BOOT_ID_BEFORE" =~ ^[0-9a-f-]{36}$ ]] || error 'The target Node bootID is invalid.'

printf '\nWorker reboot-test preflight PASSED.\n'
printf 'Target: %s (%s, %s)\n' "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP"
printf 'Kubernetes Node: %s\n' "$NODE_NAME"
printf 'Current bootID: %s\n' "$BOOT_ID_BEFORE"
printf 'Planned order: worker-0 -> worker-2 -> worker-1\n'
printf 'During the test, do not run Terraform, another failure test, or manual node maintenance.\n'

if "$PREFLIGHT_ONLY"; then
  printf 'Preflight-only mode made no AWS or OpenShift changes.\n'
  printf 'Next: bash scripts/34-test-worker-reboot.sh %s\n' "$TARGET_NAME"
  exit 0
fi

printf '\nThe script will cordon and drain one worker, send one EC2 reboot request, and recover it.\n'
printf 'It never uses --force or --disable-eviction.\n'
read -r -p "Type TEST-${TARGET_NAME^^}-REBOOT to continue: " CONFIRM
[[ "$CONFIRM" == "TEST-${TARGET_NAME^^}-REBOOT" ]] || {
  printf 'Worker reboot test cancelled.\n'
  exit 0
}

# Recheck mutable safety conditions after confirmation.
assert_all_ec2_instances_ready \
  || error 'An OpenShift EC2 instance changed after preflight.'
assert_six_nodes_ready_and_schedulable \
  || error 'A Node changed readiness or scheduling state after preflight.'
assert_machine_config_pools_stable \
  || error 'A MachineConfigPool changed after preflight.'
assert_cluster_operators_stable \
  || error 'A ClusterOperator changed after preflight.'
assert_no_pending_csrs \
  || error 'A pending CSR appeared after preflight.'
oc adm drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=20m \
  --dry-run=server >/dev/null \
  || error 'The final drain dry-run failed. No reboot was requested.'
[[ "$(get_node_uid "$NODE_NAME")" == "$NODE_UID" \
    && "$(get_node_boot_id "$NODE_NAME")" == "$BOOT_ID_BEFORE" ]] \
  || error 'The target Node identity changed after preflight.'
current_state_json="$(terraform -chdir="$TERRAFORM_DIR" state pull)" \
  || error 'Unable to re-read Terraform state before mutation.'
[[ "$(jq -r '.lineage' <<<"$current_state_json")" == "$terraform_lineage" \
    && "$(jq -r '.serial' <<<"$current_state_json")" == "$terraform_serial" ]] \
  || error 'Terraform state changed after preflight. Run preflight again.'

RECOVERY_REQUIRED=0
RECOVERY_IN_PROGRESS=0

restore_on_exit() {
  local exit_status=$?
  trap - EXIT
  if ((RECOVERY_REQUIRED == 1 && RECOVERY_IN_PROGRESS == 0)); then
    RECOVERY_IN_PROGRESS=1
    trap 'printf "Recovery is in progress; wait for completion or use --recover after an external interruption.\n" >&2' INT TERM
    printf '\nRecovering %s before exit.\n' "$TARGET_NAME" >&2
    marker_reboot_requested="$(jq -r '.reboot_may_have_been_requested // false' "$RECOVERY_FILE" 2>/dev/null || printf 'false')"
    if recover_target "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" "$NODE_NAME" \
      "$NODE_UID" "$BOOT_ID_BEFORE" "$marker_reboot_requested"; then
      RECOVERY_REQUIRED=0
    else
      print_recovery_notice
      printf 'ERROR: Automatic worker recovery did not complete.\n' >&2
      exit_status=1
    fi
  fi
  exit "$exit_status"
}

# Arm recovery before cordoning. The marker survives shell or PC failure.
write_recovery_marker "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" "$NODE_NAME" \
  "$NODE_UID" "$BOOT_ID_BEFORE"
RECOVERY_REQUIRED=1
trap 'exit 130' INT
trap 'exit 143' TERM
trap restore_on_exit EXIT

oc adm cordon "$NODE_NAME"
update_recovery_marker cordoned false

oc adm drain "$NODE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=20m
update_recovery_marker drained false
printf 'PASS: %s is cordoned and drained without bypassing PDBs.\n' "$NODE_NAME"

wait_for_workloads_ready "$NODE_NAME" \
  || error 'Ingress Router or NFS provisioner did not move away from the drained worker.'
assert_api_and_console_reachable \
  || error 'API or Console is not reachable after draining the target worker.'
printf 'PASS: Ingress Router and NFS provisioner are available away from the drained worker.\n'

# Mark the request as possible before calling the asynchronous API. Recovery never
# sends a second reboot when this flag is true.
update_recovery_marker reboot-requesting true
printf 'Sending one EC2 reboot request for %s (%s).\n' "$TARGET_NAME" "$TARGET_ID"
aws ec2 reboot-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$TARGET_ID" --no-cli-pager
update_recovery_marker reboot-requested true

BOOT_ID_AFTER="$(wait_for_boot_id_change "$NODE_NAME" "$BOOT_ID_BEFORE" "$NODE_UID")" \
  || error 'The Node bootID did not change within 20 minutes. Do not send another reboot automatically.'
update_recovery_marker boot-observed true "$BOOT_ID_AFTER"
printf 'PASS: %s bootID changed from %s to %s.\n' \
  "$TARGET_NAME" "$BOOT_ID_BEFORE" "$BOOT_ID_AFTER"

wait_for_node_ready "$NODE_NAME" \
  || error "$NODE_NAME did not become Ready within 20 minutes."
aws ec2 wait instance-status-ok \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$TARGET_ID" \
  || error 'The target EC2 instance did not pass both status checks.'
assert_target_aws_identity "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" \
  || error 'The recovered EC2 identity, private IP, VPC, or tags changed.'
wait_for_target_node_converged "$TARGET_NAME" "$TARGET_ID" "$TARGET_IP" "$NODE_UID" \
  || error 'The recovered Kubernetes Node identity or MCO state is unexpected.'
wait_for_platform_safe_before_uncordon "$NODE_NAME" \
  || error 'MCP, ClusterVersion, or ClusterOperators did not reach a safe pre-uncordon state.'
assert_no_pending_csrs \
  || error 'A pending CSR exists. Do not auto-approve it; run scripts/27-review-csrs.sh.'
wait_for_workloads_ready "$NODE_NAME" \
  || error 'Workloads did not remain available away from the cordoned worker.'

oc adm uncordon "$NODE_NAME"
update_recovery_marker uncordoned true "$BOOT_ID_AFTER"
printf 'PASS: %s is Ready and schedulable again.\n' "$NODE_NAME"

wait_for_workloads_ready \
  || error 'Ingress Router or NFS provisioner is not available after uncordon.'
wait_for_stability_window \
  || error 'The cluster did not remain stable for three consecutive samples.'
bash "$SCRIPT_DIR/29-validate-openshift-cluster.sh" \
  || error 'Final OpenShift cluster validation failed.'

write_result "$TARGET_NAME" "$TARGET_ID" "$NODE_NAME" "$NODE_UID" \
  "$BOOT_ID_BEFORE" "$BOOT_ID_AFTER"
rm -f -- "$RECOVERY_FILE"
RECOVERY_REQUIRED=0
trap - EXIT INT TERM

printf '\nWorker planned reboot test PASSED for %s.\n' "$TARGET_NAME"
printf 'Instance ID, private IP, and Node UID were retained; bootID changed.\n'
printf 'The worker is Ready and schedulable, and the recovery marker was removed.\n'
case "$TARGET_NAME" in
  worker-0)
    printf 'Next after a fresh preflight: bash scripts/34-test-worker-reboot.sh --preflight-only worker-2\n'
    ;;
  worker-2)
    printf 'Next after a fresh preflight: bash scripts/34-test-worker-reboot.sh --preflight-only worker-1\n'
    ;;
  worker-1)
    printf 'All three worker planned reboot tests are complete for this cluster.\n'
    ;;
esac
