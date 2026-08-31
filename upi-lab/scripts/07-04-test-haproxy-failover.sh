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
STATE_DIR="$HOME/.config/openshift-upi-lab"
RECOVERY_FILE="$STATE_DIR/haproxy-failover-recovery.json"
NODE_REBOOT_RECOVERY_FILE="$STATE_DIR/worker-reboot-recovery.json"
LOCK_FILE="$STATE_DIR/haproxy-failover.lock"
PREFLIGHT_ONLY=false
RECOVERY_MODE=false
TARGET_NAME=

usage() {
  cat <<'EOF'
Usage:
  bash scripts/07-04-test-haproxy-failover.sh --preflight-only haproxy-0
  bash scripts/07-04-test-haproxy-failover.sh haproxy-0
  bash scripts/07-04-test-haproxy-failover.sh --recover

Test only one HAProxy at a time. Run haproxy-1 only after haproxy-0 has been
fully restored and a new preflight has passed.
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
    haproxy-0 | haproxy-1)
      [[ -z "$TARGET_NAME" ]] || error 'Specify exactly one HAProxy target.'
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
  [[ -z "$TARGET_NAME" ]] || error '--recover reads the target from the recovery marker; do not specify a target.'
else
  [[ "$TARGET_NAME" == haproxy-0 || "$TARGET_NAME" == haproxy-1 ]] || {
    usage >&2
    error 'Specify haproxy-0 or haproxy-1.'
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

install -d -m 700 "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || error "Another HAProxy failure test or recovery is active: $LOCK_FILE"
[[ ! -e "$NODE_REBOOT_RECOVERY_FILE" ]] \
  || error "An unfinished worker reboot recovery exists. Run scripts/07-05-test-worker-reboot.sh --recover first."

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

vpc_id="$(jq -er '.vpc_id.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no vpc_id.'
[[ "$vpc_id" =~ ^vpc-[0-9a-f]+$ ]] || error 'Terraform output vpc_id is invalid.'

instances_json="$(jq -ec '.infrastructure_instances.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no infrastructure_instances map.'
haproxy_0_id="$(jq -er '.["haproxy-0"].id' <<<"$instances_json")" \
  || error 'Terraform output has no haproxy-0 instance ID.'
haproxy_1_id="$(jq -er '.["haproxy-1"].id' <<<"$instances_json")" \
  || error 'Terraform output has no haproxy-1 instance ID.'
haproxy_0_ip="$(jq -er '.["haproxy-0"].private_ip' <<<"$instances_json")" \
  || error 'Terraform output has no haproxy-0 private IP.'
haproxy_1_ip="$(jq -er '.["haproxy-1"].private_ip' <<<"$instances_json")" \
  || error 'Terraform output has no haproxy-1 private IP.'
[[ "$haproxy_0_id" =~ ^i-[0-9a-f]+$ && "$haproxy_1_id" =~ ^i-[0-9a-f]+$ ]] \
  || error 'Terraform returned an invalid HAProxy instance ID.'
[[ "$haproxy_0_ip" == 10.80.40.21 && "$haproxy_1_ip" == 10.80.50.21 ]] \
  || error 'Terraform returned unexpected HAProxy private IP addresses.'

declare -A HAPROXY_IDS=(
  [haproxy-0]="$haproxy_0_id"
  [haproxy-1]="$haproxy_1_id"
)
declare -A HAPROXY_IPS=(
  [haproxy-0]="$haproxy_0_ip"
  [haproxy-1]="$haproxy_1_ip"
)
declare -A TARGET_GROUP_PORTS=(
  [api]=6443
  [machine_config]=22623
  [ingress_http]=80
  [ingress_https]=443
)
TARGET_GROUP_NAMES=(api machine_config ingress_http ingress_https)

target_groups_json="$(jq -ec '.internal_nlb_target_groups.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no internal_nlb_target_groups map.'
jq -e --arg arn_prefix "arn:aws:elasticloadbalancing:$AWS_REGION_NAME:$aws_account:targetgroup/" '
  (keys | sort) == (["api", "ingress_http", "ingress_https", "machine_config"] | sort) and
  all(.[]; type == "string" and startswith($arn_prefix))
' <<<"$target_groups_json" >/dev/null \
  || error 'Terraform returned an unexpected set of internal NLB target groups.'

declare -A TARGET_GROUP_ARNS=()
while IFS=$'\t' read -r service_name target_group_arn; do
  TARGET_GROUP_ARNS["$service_name"]="$target_group_arn"
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$target_groups_json")

nlb_json="$(jq -ec '.internal_nlb.value' <<<"$terraform_outputs_json")" \
  || error 'Terraform output has no internal_nlb value.'
jq -e --arg arn_prefix "arn:aws:elasticloadbalancing:$AWS_REGION_NAME:$aws_account:loadbalancer/net/" '
  (.arn | type == "string" and startswith($arn_prefix)) and
  .private_ips == {
    "cluster-a": "10.80.10.5",
    "cluster-b": "10.80.20.5",
    "cluster-c": "10.80.30.5"
  }
' <<<"$nlb_json" >/dev/null \
  || error 'Terraform returned an unexpected set of internal NLB private IPs.'
nlb_arn="$(jq -er '.arn' <<<"$nlb_json")" \
  || error 'Terraform output has no internal NLB ARN.'
mapfile -t NLB_IPS < <(jq -r '.private_ips | [.["cluster-a"], .["cluster-b"], .["cluster-c"]] | .[]' <<<"$nlb_json")

describe_haproxy_instances() {
  aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$haproxy_0_id" "$haproxy_1_id" --output json
}

assert_haproxy_instance_identity() {
  local aws_instances_json
  aws_instances_json="$(describe_haproxy_instances)" \
    || error 'Unable to describe the HAProxy instances.'

  jq -e \
    --arg id0 "$haproxy_0_id" --arg id1 "$haproxy_1_id" \
    --arg ip0 "$haproxy_0_ip" --arg ip1 "$haproxy_1_ip" \
    --arg vpc "$vpc_id" '
    def tag($instance; $key):
      ([$instance.Tags[]? | select(.Key == $key) | .Value][0] // "");
    [.Reservations[].Instances[]] as $instances |
    ($instances | length) == 2 and
    any($instances[];
      .InstanceId == $id0 and .PrivateIpAddress == $ip0 and .VpcId == $vpc and
      (.PublicIpAddress // "") == "" and
      tag(.; "Name") == "openshift-upi-lab-haproxy-0" and
      tag(.; "Role") == "haproxy-0" and
      tag(.; "Project") == "openshift-upi-lab") and
    any($instances[];
      .InstanceId == $id1 and .PrivateIpAddress == $ip1 and .VpcId == $vpc and
      (.PublicIpAddress // "") == "" and
      tag(.; "Name") == "openshift-upi-lab-haproxy-1" and
      tag(.; "Role") == "haproxy-1" and
      tag(.; "Project") == "openshift-upi-lab")
  ' <<<"$aws_instances_json" >/dev/null \
    || error 'The AWS HAProxy instances do not match Terraform IDs, IPs, VPC, or tags.'
}

assert_haproxy_instances_ready() {
  local aws_instances_json instance_status_json
  aws_instances_json="$(describe_haproxy_instances)" \
    || error 'Unable to describe the HAProxy instances.'
  jq -e '
    [.Reservations[].Instances[]] |
    length == 2 and all(.[]; .State.Name == "running")
  ' <<<"$aws_instances_json" >/dev/null \
    || error 'Both HAProxy instances must be running before a failure test.'

  instance_status_json="$(aws ec2 describe-instance-status \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --include-all-instances \
    --instance-ids "$haproxy_0_id" "$haproxy_1_id" --output json)" \
    || error 'Unable to read HAProxy EC2 status checks.'
  jq -e \
    --arg id0 "$haproxy_0_id" --arg id1 "$haproxy_1_id" '
    .InstanceStatuses as $statuses |
    ($statuses | length) == 2 and
    ([ $statuses[].InstanceId ] | sort) == ([ $id0, $id1 ] | sort) and
    all($statuses[];
      .InstanceState.Name == "running" and
      .InstanceStatus.Status == "ok" and
      .SystemStatus.Status == "ok")
  ' <<<"$instance_status_json" >/dev/null \
    || error 'Both HAProxy instances must pass EC2 instance and system status checks.'
}

assert_nlb_cross_zone_enabled() {
  local attributes_json cross_zone_enabled
  attributes_json="$(aws elbv2 describe-load-balancer-attributes \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --load-balancer-arn "$nlb_arn" --output json)" \
    || error 'Unable to read internal NLB attributes.'
  cross_zone_enabled="$(jq -r '
    [.Attributes[] | select(.Key == "load_balancing.cross_zone.enabled") | .Value][0] // ""
  ' <<<"$attributes_json")"
  [[ "$cross_zone_enabled" == true ]] \
    || error 'Internal NLB cross-zone load balancing is not enabled.'
  printf 'PASS: Internal NLB cross-zone load balancing is enabled.\n'
}

target_group_health() {
  local service_name="$1"
  aws elbv2 describe-target-health \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --target-group-arn "${TARGET_GROUP_ARNS[$service_name]}" --output json
}

health_has_expected_membership() {
  local service_name="$1"
  local health_json="$2"
  local expected_port="${TARGET_GROUP_PORTS[$service_name]}"
  jq -e \
    --arg id0 "$haproxy_0_id" --arg id1 "$haproxy_1_id" \
    --argjson port "$expected_port" '
    .TargetHealthDescriptions as $targets |
    ($targets | length) == 2 and
    ([ $targets[].Target.Id ] | sort) == ([ $id0, $id1 ] | sort) and
    all($targets[]; .Target.Port == $port)
  ' <<<"$health_json" >/dev/null
}

assert_target_group_membership() {
  local service_name health_json
  for service_name in "${TARGET_GROUP_NAMES[@]}"; do
    health_json="$(target_group_health "$service_name")" \
      || error "Unable to read target health for $service_name."
    health_has_expected_membership "$service_name" "$health_json" \
      || error "Target group $service_name does not contain exactly the two expected HAProxy instances."
  done
}

assert_all_target_groups_healthy() {
  local service_name health_json healthy_count
  assert_target_group_membership
  for service_name in "${TARGET_GROUP_NAMES[@]}"; do
    health_json="$(target_group_health "$service_name")" \
      || error "Unable to read target health for $service_name."
    healthy_count="$(jq -r '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$health_json")"
    [[ "$healthy_count" == 2 ]] \
      || error "Target group $service_name has $healthy_count/2 healthy HAProxy targets."
    printf 'PASS: Target group %s has 2/2 healthy HAProxy targets.\n' "$service_name"
  done
}

wait_for_single_healthy_target() {
  local stopped_id="$1"
  local peer_id="$2"
  local attempt service_name health_json all_ready

  for ((attempt = 1; attempt <= 180; attempt++)); do
    all_ready=true
    for service_name in "${TARGET_GROUP_NAMES[@]}"; do
      if ! health_json="$(target_group_health "$service_name" 2>/dev/null)"; then
        all_ready=false
        continue
      fi
      if ! health_has_expected_membership "$service_name" "$health_json"; then
        all_ready=false
        continue
      fi
      if ! jq -e --arg stopped "$stopped_id" --arg peer "$peer_id" '
        .TargetHealthDescriptions as $targets |
        any($targets[]; .Target.Id == $peer and .TargetHealth.State == "healthy") and
        any($targets[]; .Target.Id == $stopped and .TargetHealth.State != "healthy")
      ' <<<"$health_json" >/dev/null; then
        all_ready=false
      fi
    done
    "$all_ready" && return 0
    ((attempt % 6 == 0)) \
      && printf 'Waiting for all four target groups to converge to the peer HAProxy only (%ds elapsed).\n' "$((attempt * 5))"
    sleep 5
  done
  return 1
}

wait_for_all_target_groups_healthy() {
  local attempt service_name health_json all_ready

  for ((attempt = 1; attempt <= 240; attempt++)); do
    all_ready=true
    for service_name in "${TARGET_GROUP_NAMES[@]}"; do
      if ! health_json="$(target_group_health "$service_name" 2>/dev/null)"; then
        all_ready=false
        continue
      fi
      if ! health_has_expected_membership "$service_name" "$health_json"; then
        all_ready=false
        continue
      fi
      if ! jq -e '
        [.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length == 2
      ' <<<"$health_json" >/dev/null; then
        all_ready=false
      fi
    done
    "$all_ready" && return 0
    ((attempt % 6 == 0)) \
      && printf 'Waiting for all four target groups to return to 2/2 healthy (%ds elapsed).\n' "$((attempt * 5))"
    sleep 5
  done
  return 1
}

write_recovery_marker() {
  local target_name="$1"
  local target_id="$2"
  local temp_file
  temp_file="$(mktemp "$STATE_DIR/.haproxy-failover-recovery.XXXXXX")"
  chmod 600 "$temp_file"
  jq -n \
    --arg account_id "$aws_account" \
    --arg region "$AWS_REGION_NAME" \
    --arg workspace "$terraform_workspace" \
    --arg target_name "$target_name" \
    --arg target_instance_id "$target_id" \
    --arg created_at "$(date --iso-8601=seconds)" \
    '{
      account_id: $account_id,
      region: $region,
      terraform_workspace: $workspace,
      target_name: $target_name,
      target_instance_id: $target_instance_id,
      created_at: $created_at
    }' >"$temp_file"
  mv -- "$temp_file" "$RECOVERY_FILE"
}

print_recovery_notice() {
  printf 'Recovery marker: %s\n' "$RECOVERY_FILE" >&2
  if [[ -s "$RECOVERY_FILE" ]]; then
    jq -r '"Recorded target: \(.target_name) (\(.target_instance_id)), created \(.created_at)"' \
      "$RECOVERY_FILE" >&2 || true
  fi
  printf 'Run this command before starting another test:\n' >&2
  printf '  bash scripts/07-04-test-haproxy-failover.sh --recover\n' >&2
}

start_and_restore_target() {
  local target_name="$1"
  local target_id="$2"
  local instance_state

  instance_state="$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)" || return 1

  case "$instance_state" in
    stopped)
      printf 'Starting %s (%s).\n' "$target_name" "$target_id"
      aws ec2 start-instances \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" --no-cli-pager >/dev/null || return 1
      ;;
    stopping)
      printf 'Waiting for %s to finish stopping before recovery.\n' "$target_name"
      aws ec2 wait instance-stopped \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" || return 1
      aws ec2 start-instances \
        --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
        --instance-ids "$target_id" --no-cli-pager >/dev/null || return 1
      ;;
    pending | running)
      printf '%s is already %s; continuing recovery checks.\n' "$target_name" "$instance_state"
      ;;
    *)
      printf 'ERROR: Cannot recover %s from EC2 state %s.\n' "$target_name" "$instance_state" >&2
      return 1
      ;;
  esac

  aws ec2 wait instance-running \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" || return 1
  aws ec2 wait instance-status-ok \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --instance-ids "$target_id" || return 1
  printf 'PASS: %s is running and both EC2 status checks are OK.\n' "$target_name"

  wait_for_all_target_groups_healthy || return 1
  printf 'PASS: All four target groups are restored to 2/2 healthy.\n'

  bash "$SCRIPT_DIR/06-15-validate-openshift-cluster.sh" || return 1
  rm -f -- "$RECOVERY_FILE" || return 1
  printf 'PASS: %s recovery completed and the recovery marker was removed.\n' "$target_name"
}

assert_haproxy_instance_identity

if [[ -e "$RECOVERY_FILE" ]]; then
  [[ -s "$RECOVERY_FILE" ]] || error "Recovery marker exists but is empty: $RECOVERY_FILE"
  if ! "$RECOVERY_MODE"; then
    print_recovery_notice
    error 'An unfinished HAProxy recovery exists; refusing to start another test.'
  fi

  marker_account="$(jq -er '.account_id' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid account_id.'
  marker_region="$(jq -er '.region' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid region.'
  marker_workspace="$(jq -er '.terraform_workspace' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid terraform_workspace.'
  marker_target_name="$(jq -er '.target_name' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid target_name.'
  marker_target_id="$(jq -er '.target_instance_id' "$RECOVERY_FILE")" \
    || error 'Recovery marker has no valid target_instance_id.'
  [[ "$marker_account" == "$aws_account" && "$marker_region" == "$AWS_REGION_NAME" \
      && "$marker_workspace" == "$terraform_workspace" ]] \
    || error 'Recovery marker account, region, or Terraform workspace does not match the current environment.'
  [[ "$marker_target_name" == haproxy-0 || "$marker_target_name" == haproxy-1 ]] \
    || error 'Recovery marker contains an unexpected HAProxy name.'
  [[ "${HAPROXY_IDS[$marker_target_name]}" == "$marker_target_id" ]] \
    || error 'Recovery marker instance ID does not match the current Terraform output.'

  printf 'This restores %s (%s) and verifies all four target groups and the OpenShift cluster.\n' \
    "$marker_target_name" "$marker_target_id"
  read -r -p "Type RECOVER-${marker_target_name^^} to continue: " CONFIRM
  [[ "$CONFIRM" == "RECOVER-${marker_target_name^^}" ]] || {
    printf 'Recovery cancelled. The recovery marker was retained.\n'
    exit 0
  }
  start_and_restore_target "$marker_target_name" "$marker_target_id" || {
    print_recovery_notice
    error 'Recovery did not complete. The recovery marker was retained.'
  }
  printf 'HAProxy recovery PASSED.\n'
  exit 0
fi

"$RECOVERY_MODE" && error "No recovery marker exists: $RECOVERY_FILE"

phase6_require_file "$INSTALL_DIR/install-complete.ok"
assert_target_group_membership
phase7_assert_target_cluster "$INSTALL_DIR/auth/kubeconfig"
assert_haproxy_instances_ready
assert_nlb_cross_zone_enabled
assert_all_target_groups_healthy

printf '\nRunning the full cluster validation before the failure test.\n'
bash "$SCRIPT_DIR/06-15-validate-openshift-cluster.sh" \
  || error 'The OpenShift cluster baseline validation failed.'

if [[ "$TARGET_NAME" == haproxy-0 ]]; then
  PEER_NAME=haproxy-1
else
  PEER_NAME=haproxy-0
fi
TARGET_ID="${HAPROXY_IDS[$TARGET_NAME]}"
PEER_ID="${HAPROXY_IDS[$PEER_NAME]}"

printf '\nHAProxy failure-test preflight PASSED.\n'
printf 'Target to stop temporarily: %s (%s, %s)\n' \
  "$TARGET_NAME" "$TARGET_ID" "${HAPROXY_IPS[$TARGET_NAME]}"
printf 'Peer that remains active: %s (%s, %s)\n' \
  "$PEER_NAME" "$PEER_ID" "${HAPROXY_IPS[$PEER_NAME]}"
printf 'During the test, do not run Terraform or stop the peer HAProxy.\n'

if "$PREFLIGHT_ONLY"; then
  printf 'Preflight-only mode made no EC2 changes.\n'
  printf 'Next: bash scripts/07-04-test-haproxy-failover.sh %s\n' "$TARGET_NAME"
  exit 0
fi

printf '\nThe target is stopped only after confirmation and is restored automatically.\n'
printf 'NLB health convergence normally takes at least about 60 seconds.\n'
read -r -p "Type TEST-${TARGET_NAME^^}-FAILOVER to continue: " CONFIRM
[[ "$CONFIRM" == "TEST-${TARGET_NAME^^}-FAILOVER" ]] || {
  printf 'HAProxy failure test cancelled.\n'
  exit 0
}

# Recheck the mutable prerequisites after the operator confirmation.
assert_haproxy_instances_ready
assert_all_target_groups_healthy

RESTORE_REQUIRED=0
RECOVERY_IN_PROGRESS=0

restore_on_exit() {
  local exit_status=$?
  trap - EXIT
  if ((RESTORE_REQUIRED == 1 && RECOVERY_IN_PROGRESS == 0)); then
    RECOVERY_IN_PROGRESS=1
    trap 'printf "Recovery is in progress; wait for completion or use --recover after an external interruption.\n" >&2' INT TERM
    printf '\nRestoring %s before exit.\n' "$TARGET_NAME" >&2
    if start_and_restore_target "$TARGET_NAME" "$TARGET_ID"; then
      RESTORE_REQUIRED=0
    else
      print_recovery_notice
      printf 'ERROR: Automatic HAProxy recovery did not complete.\n' >&2
      exit_status=1
    fi
  fi
  exit "$exit_status"
}

trap 'exit 130' INT
trap 'exit 143' TERM
trap restore_on_exit EXIT

# Arm recovery before the stop request. The marker survives a shell or PC failure.
RESTORE_REQUIRED=1
write_recovery_marker "$TARGET_NAME" "$TARGET_ID"

printf 'Stopping %s (%s).\n' "$TARGET_NAME" "$TARGET_ID"
aws ec2 stop-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$TARGET_ID" --no-cli-pager >/dev/null
aws ec2 wait instance-stopped \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$TARGET_ID"
printf 'PASS: %s is stopped.\n' "$TARGET_NAME"

wait_for_single_healthy_target "$TARGET_ID" "$PEER_ID" \
  || error 'The four target groups did not converge to the peer HAProxy within 15 minutes.'
printf 'PASS: All four target groups use %s as their only healthy HAProxy target.\n' "$PEER_NAME"

console_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
[[ "$console_host" == console-openshift-console.apps.ocp.lab.k8study.com ]] \
  || error "Unexpected console route host: $console_host"

check_nlb_endpoint_with_retry() {
  local description="$1"
  local resolve_entry="$2"
  local url="$3"
  local request_method="$4"
  local attempt success_streak=0
  local -a curl_args=(
    --fail --silent --show-error --insecure
    --connect-timeout 5 --max-time 10
    --resolve "$resolve_entry"
  )

  if [[ "$request_method" == HEAD ]]; then
    curl_args+=(--head)
  fi

  for ((attempt = 1; attempt <= 24; attempt++)); do
    if curl "${curl_args[@]}" "$url" >/dev/null; then
      success_streak=$((success_streak + 1))
      if ((success_streak == 3)); then
        printf 'PASS: %s succeeded three consecutive times.\n' "$description"
        return 0
      fi
    else
      success_streak=0
      printf 'Transient failure: %s; retrying (%d/24).\n' "$description" "$attempt" >&2
    fi
    ((attempt < 24)) && sleep 2
  done

  return 1
}

for nlb_ip in "${NLB_IPS[@]}"; do
  check_nlb_endpoint_with_retry \
    "API readyz through NLB frontend $nlb_ip" \
    "api.ocp.lab.k8study.com:6443:$nlb_ip" \
    https://api.ocp.lab.k8study.com:6443/readyz GET \
    || error "API readyz failed through NLB frontend $nlb_ip."
  check_nlb_endpoint_with_retry \
    "Console route through NLB frontend $nlb_ip" \
    "$console_host:443:$nlb_ip" \
    "https://$console_host" HEAD \
    || error "Console route failed through NLB frontend $nlb_ip."
  printf 'PASS: API and Console remain reachable through NLB frontend %s.\n' "$nlb_ip"
done

nodes_json="$(oc get nodes -o json)"
ready_node_count="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
[[ "$(jq -r '.items | length' <<<"$nodes_json")" == 6 && "$ready_node_count" == 6 ]] \
  || error 'The six permanent nodes are not all Ready during the single-side failure.'
printf 'PASS: All six permanent nodes remain Ready through the peer HAProxy.\n'

cluster_available="$(oc get clusterversion version -o json | jq -r '
  any(.status.conditions[]; .type == "Available" and .status == "True")
')"
[[ "$cluster_available" == true ]] \
  || error 'ClusterVersion is not Available during the single-side failure.'
bad_operator_count="$(oc get clusteroperators -o json | jq -r '[.items[] | select(
  (any(.status.conditions[]; .type == "Available" and .status == "True") | not) or
  any(.status.conditions[]; .type == "Progressing" and .status == "True") or
  any(.status.conditions[]; .type == "Degraded" and .status == "True")
)] | length')"
[[ "$bad_operator_count" == 0 ]] \
  || error "$bad_operator_count ClusterOperators are not stable during the single-side failure."
printf 'PASS: ClusterVersion and all ClusterOperators remain stable through the peer HAProxy.\n'

printf '\nSingle-side HAProxy continuity checks PASSED. Restoring the stopped instance.\n'
start_and_restore_target "$TARGET_NAME" "$TARGET_ID" \
  || error 'Automatic HAProxy recovery did not complete.'
RESTORE_REQUIRED=0
trap - EXIT INT TERM

printf '\nHAProxy single-side failure test PASSED for %s.\n' "$TARGET_NAME"
printf 'The instance is running again and all four target groups are 2/2 healthy.\n'
if [[ "$TARGET_NAME" == haproxy-0 ]]; then
  printf 'Optional next test after a fresh preflight: bash scripts/07-04-test-haproxy-failover.sh --preflight-only haproxy-1\n'
fi
