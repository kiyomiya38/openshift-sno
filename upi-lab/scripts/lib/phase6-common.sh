#!/usr/bin/env bash

PHASE6_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=safety-common.sh
source "$PHASE6_LIB_DIR/safety-common.sh"

[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-openshift-lab}"
AWS_REGION_NAME="${AWS_REGION_NAME:-ap-northeast-3}"
PHASE6_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE6_REPO_DIR="$(cd -- "$PHASE6_SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-$PHASE6_REPO_DIR/terraform}"
ANSIBLE_DIR="${ANSIBLE_DIR:-$PHASE6_REPO_DIR/ansible}"
ASSET_ROOT="${ASSET_ROOT:-$HOME/.local/share/openshift-upi-lab}"
INSTALL_DIR="${INSTALL_DIR:-$ASSET_ROOT/install}"
CLUSTER_ENV_FILE="${CLUSTER_ENV_FILE:-$ASSET_ROOT/cluster.env}"
CLUSTER_STAGE_FILE="${CLUSTER_STAGE_FILE:-$HOME/.config/openshift-upi-lab/cluster-stage}"
CERTIFICATE_ARN_FILE="${CERTIFICATE_ARN_FILE:-$HOME/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt}"
PHASE6_VERIFIED_OPENSHIFT_VERSION='4.21.26'
EXPECTED_OPENSHIFT_VERSION="${EXPECTED_OPENSHIFT_VERSION:-$PHASE6_VERIFIED_OPENSHIFT_VERSION}"

phase6_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

phase6_require_command() {
  command -v "$1" >/dev/null 2>&1 || phase6_error "Required command is not installed: $1"
}

phase6_require_file() {
  [[ -s "$1" ]] || phase6_error "Required file is missing or empty: $1"
}

phase6_assert_execution_context() {
  lab_assert_default_workspace "$TERRAFORM_DIR" \
    || phase6_error 'Terraform execution context validation failed.'
  lab_export_expected_account_id strict "$TERRAFORM_DIR" "$CERTIFICATE_ARN_FILE" \
    || phase6_error 'Expected AWS account validation failed.'
  lab_assert_aws_identity "$TF_VAR_expected_account_id" "$AWS_PROFILE_NAME" "$AWS_REGION_NAME" \
    || phase6_error 'AWS execution context validation failed.'
}

phase6_export_base_terraform_vars() {
  phase6_require_file "$CERTIFICATE_ARN_FILE"
  phase6_assert_execution_context
  export TF_VAR_enable_client_vpn=true
  export TF_VAR_client_vpn_server_certificate_arn
  TF_VAR_client_vpn_server_certificate_arn="$(<"$CERTIFICATE_ARN_FILE")"
  export TF_VAR_enable_infrastructure_services=true
  export TF_VAR_client_vpn_dns_servers='["10.80.40.11","10.80.50.11"]'
}

phase6_load_cluster_env() {
  phase6_require_file "$CLUSTER_ENV_FILE"
  # This file is generated locally by scripts/06-01-prepare-openshift-install.sh
  # and scripts/06-04-generate-stage-ignition.sh with shell-escaped values.
  # shellcheck disable=SC1090
  source "$CLUSTER_ENV_FILE"

  [[ ${RHCOS_AMI_ID:-} =~ ^ami-[0-9a-f]{8,17}$ ]] || phase6_error 'cluster.env has an invalid RHCOS_AMI_ID.'
}

phase6_require_complete_assets() {
  phase6_load_cluster_env

  [[ ${INFRA_ID:-} =~ ^[a-z0-9-]+$ ]] || phase6_error 'cluster.env has an invalid or missing INFRA_ID.'
  [[ ${IGNITION_BASE_URL:-} == "http://10.80.40.10:8080/${INFRA_ID}" ]] || phase6_error 'cluster.env has an unexpected IGNITION_BASE_URL.'
  [[ ${IGNITION_SPEC_VERSION:-} =~ ^3\.[0-9]+\.[0-9]+$ ]] || phase6_error 'cluster.env has an invalid Ignition specification version.'

  local digest_name
  for digest_name in BOOTSTRAP_IGNITION_SHA512 MASTER_IGNITION_SHA512 WORKER_IGNITION_SHA512; do
    [[ ${!digest_name:-} =~ ^[0-9a-f]{128}$ ]] || phase6_error "cluster.env has an invalid $digest_name."
  done

  phase6_require_file "$INSTALL_DIR/bootstrap.ign"
  phase6_require_file "$INSTALL_DIR/master.ign"
  phase6_require_file "$INSTALL_DIR/worker.ign"
}

phase6_expected_node_ip() {
  case "$1" in
    control-plane-0.ocp.lab.k8study.com | worker-0.ocp.lab.k8study.com)
      [[ "$1" == control-plane-0.* ]] && printf '10.80.10.10\n' || printf '10.80.10.20\n'
      ;;
    control-plane-1.ocp.lab.k8study.com | worker-1.ocp.lab.k8study.com)
      [[ "$1" == control-plane-1.* ]] && printf '10.80.20.10\n' || printf '10.80.20.20\n'
      ;;
    control-plane-2.ocp.lab.k8study.com | worker-2.ocp.lab.k8study.com)
      [[ "$1" == control-plane-2.* ]] && printf '10.80.30.10\n' || printf '10.80.30.20\n'
      ;;
    *)
      return 1
      ;;
  esac
}

phase6_expected_nodes_json() {
  jq -cn '[
    {name:"control-plane-0.ocp.lab.k8study.com",ip:"10.80.10.10",role:"control-plane"},
    {name:"control-plane-1.ocp.lab.k8study.com",ip:"10.80.20.10",role:"control-plane"},
    {name:"control-plane-2.ocp.lab.k8study.com",ip:"10.80.30.10",role:"control-plane"},
    {name:"worker-0.ocp.lab.k8study.com",ip:"10.80.10.20",role:"worker"},
    {name:"worker-1.ocp.lab.k8study.com",ip:"10.80.20.20",role:"worker"},
    {name:"worker-2.ocp.lab.k8study.com",ip:"10.80.30.20",role:"worker"}
  ]'
}

phase6_actual_nodes_json() {
  local nodes_json="$1"

  jq -c '[.items[] | {
    name: .metadata.name,
    ip: ([.status.addresses[]? | select(.type == "InternalIP") | .address]
      | if length == 1 then .[0] else join(",") end),
    role: (
      if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "control-plane"
      elif .metadata.labels["node-role.kubernetes.io/worker"] != null then "worker"
      else ""
      end
    )
  }]' <<<"$nodes_json"
}

phase6_assert_expected_node_subset() {
  local nodes_json="$1"
  local expected_nodes actual_nodes unexpected_nodes

  expected_nodes="$(phase6_expected_nodes_json)"
  actual_nodes="$(phase6_actual_nodes_json "$nodes_json")"
  unexpected_nodes="$(jq -c --argjson expected "$expected_nodes" \
    '[.[] | . as $node | select(any($expected[]; . == $node) | not)]' \
    <<<"$actual_nodes")"

  if [[ "$(jq 'length' <<<"$unexpected_nodes")" != 0 ]]; then
    printf 'Unexpected registered node identity, InternalIP, or role:\n' >&2
    jq -r '.[] | "  name=\(.name) ip=\(.ip) role=\(.role)"' \
      <<<"$unexpected_nodes" >&2
    phase6_error 'Registered nodes do not match the OpenShift UPI lab design.'
  fi
}

phase6_expected_node_inventory_complete() {
  local nodes_json="$1"
  local expected_nodes actual_nodes

  expected_nodes="$(phase6_expected_nodes_json)"
  actual_nodes="$(phase6_actual_nodes_json "$nodes_json")"
  jq -e --argjson expected "$expected_nodes" \
    'sort_by(.name) == ($expected | sort_by(.name))' \
    <<<"$actual_nodes" >/dev/null
}

phase6_assert_expected_node_inventory() {
  local nodes_json="$1"
  local actual_nodes

  phase6_assert_expected_node_subset "$nodes_json"
  if ! phase6_expected_node_inventory_complete "$nodes_json"; then
    actual_nodes="$(phase6_actual_nodes_json "$nodes_json")"
    printf 'Registered node inventory is incomplete:\n' >&2
    jq -r '.[] | "  name=\(.name) ip=\(.ip) role=\(.role)"' \
      <<<"$actual_nodes" >&2
    phase6_error 'Expected exactly the six designed OpenShift nodes.'
  fi
}

PHASE6_CSR_ELIGIBILITY_REASON=''

phase6_csr_is_expected_node_request() {
  local csr_json="$1"
  local request_file="$2"
  local signer requestor subject subject_compact node_fqdn expected_ip
  local usages san_output san_entries expected_san_entries

  PHASE6_CSR_ELIGIBILITY_REASON=''
  if ! openssl req -in "$request_file" -noout -verify >/dev/null 2>&1; then
    PHASE6_CSR_ELIGIBILITY_REASON='The certificate request signature is invalid.'
    return 1
  fi

  subject="$(openssl req -in "$request_file" -noout -subject -nameopt RFC2253 2>/dev/null)" || {
    PHASE6_CSR_ELIGIBILITY_REASON='The certificate request subject cannot be decoded.'
    return 1
  }
  subject_compact="${subject//[[:space:]]/}"
  if [[ "$subject_compact" =~ CN=system:node:([^,]+) ]]; then
    node_fqdn="${BASH_REMATCH[1]}"
  else
    PHASE6_CSR_ELIGIBILITY_REASON='The subject CN is not an expected system:node identity.'
    return 1
  fi

  expected_ip="$(phase6_expected_node_ip "$node_fqdn" 2>/dev/null)" || {
    PHASE6_CSR_ELIGIBILITY_REASON="The node FQDN is not in the lab design: $node_fqdn"
    return 1
  }
  if [[ "$subject_compact" != "subject=CN=system:node:${node_fqdn},O=system:nodes" &&
        "$subject_compact" != "subject=O=system:nodes,CN=system:node:${node_fqdn}" ]]; then
    PHASE6_CSR_ELIGIBILITY_REASON='The subject contains an unexpected organization or attribute.'
    return 1
  fi

  signer="$(jq -r '.spec.signerName // ""' <<<"$csr_json")"
  requestor="$(jq -r '.spec.username // ""' <<<"$csr_json")"
  usages="$(jq -r '(.spec.usages // []) | sort | join(",")' <<<"$csr_json")"
  san_output="$(openssl req -in "$request_file" -noout -text 2>/dev/null |
    sed -n '/X509v3 Subject Alternative Name:/{n;p;}')"

  case "$signer" in
    kubernetes.io/kube-apiserver-client-kubelet)
      [[ "$requestor" == system:serviceaccount:openshift-machine-config-operator:node-bootstrapper ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON='The kubelet client CSR Requestor is not node-bootstrapper.'
        return 1
      }
      [[ "$usages" == 'client auth,digital signature' ||
        "$usages" == 'client auth,digital signature,key encipherment' ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON="The kubelet client CSR usages are unexpected: $usages"
        return 1
      }
      [[ -z "$san_output" ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON='A kubelet client CSR must not contain a Subject Alternative Name.'
        return 1
      }
      ;;
    kubernetes.io/kubelet-serving)
      [[ "$requestor" == "system:node:${node_fqdn}" ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON='The kubelet serving CSR Requestor does not match its subject CN.'
        return 1
      }
      [[ "$usages" == 'digital signature,server auth' ||
        "$usages" == 'digital signature,key encipherment,server auth' ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON="The kubelet serving CSR usages are unexpected: $usages"
        return 1
      }
      [[ -n "$san_output" ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON='The kubelet serving CSR has no Subject Alternative Name.'
        return 1
      }
      san_entries="$(tr -d '[:space:]' <<<"$san_output" |
        tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort)"
      expected_san_entries="$(printf 'DNS:%s\nIPAddress:%s\n' "$node_fqdn" "$expected_ip" |
        LC_ALL=C sort)"
      [[ "$san_entries" == "$expected_san_entries" ]] || {
        PHASE6_CSR_ELIGIBILITY_REASON="The serving CSR SAN set is not exactly DNS:${node_fqdn} and IPAddress:${expected_ip}."
        return 1
      }
      ;;
    *)
      PHASE6_CSR_ELIGIBILITY_REASON="Signer is not eligible for manual node bootstrap approval: $signer"
      return 1
      ;;
  esac

  return 0
}

phase6_assert_assets_fresh() {
  [[ ${ASSET_GENERATED_EPOCH:-} =~ ^[0-9]+$ ]] || phase6_error 'cluster.env has no valid ASSET_GENERATED_EPOCH.'

  local age_seconds
  age_seconds=$(( $(date +%s) - ASSET_GENERATED_EPOCH ))
  (( age_seconds >= 0 )) || phase6_error 'The local clock is earlier than the Ignition generation time.'
  (( age_seconds < 43200 )) || phase6_error 'Ignition is 12 hours old or older. Restart the OpenShift installation procedure with scripts/06-01-prepare-openshift-install.sh.'
}

phase6_export_asset_terraform_vars() {
  phase6_require_complete_assets

  export TF_VAR_rhcos_ami_id="$RHCOS_AMI_ID"
  export TF_VAR_ignition_base_url="$IGNITION_BASE_URL"
  export TF_VAR_ignition_spec_version="$IGNITION_SPEC_VERSION"
  export TF_VAR_ignition_sha512
  TF_VAR_ignition_sha512="$(jq -cn \
    --arg bootstrap "$BOOTSTRAP_IGNITION_SHA512" \
    --arg master "$MASTER_IGNITION_SHA512" \
    --arg worker "$WORKER_IGNITION_SHA512" \
    '{bootstrap:$bootstrap,master:$master,worker:$worker}')"
}

phase6_set_terraform_stage() {
  local prerequisites="$1"
  local nodes="$2"
  local bootstrap="$3"

  export TF_VAR_enable_cluster_prerequisites="$prerequisites"
  export TF_VAR_enable_cluster_nodes="$nodes"
  export TF_VAR_enable_bootstrap="$bootstrap"
}

phase6_managed_plan_changes_json() {
  local plan_file="$1"

  terraform -chdir="$TERRAFORM_DIR" show -json "$plan_file" |
    jq -c '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | {address,actions:.change.actions}]'
}

phase6_assert_node_plan() {
  local changes_json="$1"
  local actual expected

  actual="$(jq -r '.[] | "\(.address):\(.actions | join(","))"' \
    <<<"$changes_json" | LC_ALL=C sort)"
  expected="$(printf '%s\n' \
    'aws_instance.openshift["bootstrap"]:create' \
    'aws_instance.openshift["control-plane-0"]:create' \
    'aws_instance.openshift["control-plane-1"]:create' \
    'aws_instance.openshift["control-plane-2"]:create' \
    'aws_instance.openshift["worker-0"]:create' \
    'aws_instance.openshift["worker-1"]:create' \
    'aws_instance.openshift["worker-2"]:create' | LC_ALL=C sort)"
  [[ "$actual" == "$expected" ]] \
    || phase6_error 'Plan does not exactly create Bootstrap, three control-plane nodes, and three workers.'
}

phase6_assert_bootstrap_removal_plan() {
  local changes_json="$1"
  jq -e 'length == 1 and
    .[0].address == "aws_instance.openshift[\"bootstrap\"]" and
    .[0].actions == ["delete"]' <<<"$changes_json" >/dev/null \
    || phase6_error 'Plan does not contain exactly one deletion of the Bootstrap instance.'
}

phase6_assert_plan_account() {
  local plan_file="$1"
  local planned_account

  planned_account="$(terraform -chdir="$TERRAFORM_DIR" show -json "$plan_file" |
    jq -er '.variables.expected_account_id.value')" \
    || phase6_error 'Saved Plan has no expected_account_id.'
  [[ "$planned_account" == "$TF_VAR_expected_account_id" ]] \
    || phase6_error 'Saved Plan account does not match the independently registered account.'
}

phase6_prerequisite_plan_kind() {
  local changes_json="$1"
  local actual_actions expected_creates expected_migration_creates expected_attachment expected_combined

  actual_actions="$(jq -r '.[] | "\(.address):\(.actions | join(","))"' <<<"$changes_json" | LC_ALL=C sort)"
  expected_creates="$(printf '%s\n' \
    'aws_security_group.openshift_control_plane[0]:create' \
    'aws_security_group.openshift_nodes[0]:create' \
    'aws_security_group.openshift_worker[0]:create' \
    'aws_vpc_dhcp_options.cluster[0]:create' \
    'aws_vpc_dhcp_options_association.cluster[0]:create' \
    'aws_vpc_security_group_ingress_rule.ignition_http_from_nodes[0]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_from_haproxy["api"]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_from_haproxy["ingress_http"]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_from_haproxy["ingress_https"]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_from_haproxy["machine_config"]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_nodes_from_self[0]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_ssh_from_infrastructure[0]:create' \
    'aws_vpc_security_group_ingress_rule.openshift_ssh_from_vpn[0]:create' |
    LC_ALL=C sort)"
  expected_migration_creates="$(printf '%s\n%s\n' \
    "$expected_creates" 'aws_security_group.ignition_server[0]:create' | LC_ALL=C sort)"
  expected_attachment='aws_instance.infrastructure["installer"]:update'
  expected_combined="$(printf '%s\n%s\n' "$expected_migration_creates" "$expected_attachment" | LC_ALL=C sort)"

  if [[ -z "$actual_actions" ]]; then
    printf 'converged\n'
  elif [[ "$actual_actions" == "$expected_migration_creates" ]]; then
    printf 'resources\n'
  elif [[ "$actual_actions" == "$expected_creates" ]]; then
    printf 'prerequisites\n'
  elif [[ "$actual_actions" == "$expected_attachment" ]]; then
    printf 'attachment\n'
  elif [[ "$actual_actions" == "$expected_combined" ]]; then
    printf 'combined\n'
  else
    return 1
  fi
}

phase6_write_cluster_env() {
  local temp_file
  install -d -m 700 "$ASSET_ROOT"
  temp_file="$(mktemp "$ASSET_ROOT/.cluster.env.XXXXXX")"
  chmod 600 "$temp_file"

  {
    printf 'RHCOS_AMI_ID=%q\n' "${RHCOS_AMI_ID:-}"
    printf 'OPENSHIFT_INSTALL_VERSION=%q\n' "${OPENSHIFT_INSTALL_VERSION:-}"
    printf 'INSTALL_CONFIG_CREATED_AT=%q\n' "${INSTALL_CONFIG_CREATED_AT:-}"
    printf 'INFRA_ID=%q\n' "${INFRA_ID:-}"
    printf 'IGNITION_BASE_URL=%q\n' "${IGNITION_BASE_URL:-}"
    printf 'IGNITION_SPEC_VERSION=%q\n' "${IGNITION_SPEC_VERSION:-}"
    printf 'BOOTSTRAP_IGNITION_SHA512=%q\n' "${BOOTSTRAP_IGNITION_SHA512:-}"
    printf 'MASTER_IGNITION_SHA512=%q\n' "${MASTER_IGNITION_SHA512:-}"
    printf 'WORKER_IGNITION_SHA512=%q\n' "${WORKER_IGNITION_SHA512:-}"
    printf 'ASSET_GENERATED_AT=%q\n' "${ASSET_GENERATED_AT:-}"
    printf 'ASSET_GENERATED_EPOCH=%q\n' "${ASSET_GENERATED_EPOCH:-}"
  } >"$temp_file"

  mv -- "$temp_file" "$CLUSTER_ENV_FILE"
}
