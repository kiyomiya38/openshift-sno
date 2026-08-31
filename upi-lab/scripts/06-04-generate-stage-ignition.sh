#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

for command_name in ansible-playbook aws jq openshift-install sed sha512sum terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context
phase6_load_cluster_env

terraform -chdir="$TERRAFORM_DIR" state show 'aws_vpc_dhcp_options.cluster[0]' >/dev/null 2>&1 \
  || phase6_error 'Cluster prerequisites are not in Terraform state. Complete scripts/06-02-plan-cluster-prerequisites.sh and scripts/06-03-apply-cluster-prerequisites.sh first.'

ignition_sg_id="$(terraform -chdir="$TERRAFORM_DIR" output -raw ignition_server_security_group_id 2>/dev/null || true)"
installer_id="$(terraform -chdir="$TERRAFORM_DIR" output -json infrastructure_instances | jq -er '.installer.id')"
installer_sg_ids_json="$(aws ec2 describe-instances \
  --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
  --instance-ids "$installer_id" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output json)"
[[ "$ignition_sg_id" == sg-* ]] \
  || phase6_error 'Ignition Server Security Group output is missing. Complete every required pass of scripts/06-02-plan-cluster-prerequisites.sh and scripts/06-03-apply-cluster-prerequisites.sh first.'
jq -e --arg security_group_id "$ignition_sg_id" \
  'index($security_group_id) != null' <<<"$installer_sg_ids_json" >/dev/null \
  || phase6_error 'Installer does not have the Ignition Server Security Group. Run scripts/06-02-plan-cluster-prerequisites.sh and scripts/06-03-apply-cluster-prerequisites.sh again before generating Ignition.'

if [[ -s "$INSTALL_DIR/install-config.yaml" ]]; then
  openshift-install create manifests --dir "$INSTALL_DIR"

  scheduler_manifest="$INSTALL_DIR/manifests/cluster-scheduler-02-config.yml"
  phase6_require_file "$scheduler_manifest"
  sed -i 's/mastersSchedulable:[[:space:]]*true/mastersSchedulable: false/' "$scheduler_manifest"
  grep -Eq 'mastersSchedulable:[[:space:]]*false' "$scheduler_manifest" \
    || phase6_error 'Failed to set mastersSchedulable: false.'

  openshift-install create ignition-configs --dir "$INSTALL_DIR"
  INFRA_ID="$(jq -er '.infraID | select(test("^[a-z0-9-]+$"))' "$INSTALL_DIR/metadata.json")"

  bootstrap_version="$(jq -er '.ignition.version' "$INSTALL_DIR/bootstrap.ign")"
  master_version="$(jq -er '.ignition.version' "$INSTALL_DIR/master.ign")"
  worker_version="$(jq -er '.ignition.version' "$INSTALL_DIR/worker.ign")"
  [[ "$bootstrap_version" == "$master_version" && "$master_version" == "$worker_version" ]] \
    || phase6_error 'Generated Ignition files use different specification versions.'
  [[ "$bootstrap_version" =~ ^3\.[0-9]+\.[0-9]+$ ]] \
    || phase6_error "Unexpected Ignition specification version: $bootstrap_version"

  (
    cd "$INSTALL_DIR"
    sha512sum bootstrap.ign master.ign worker.ign >SHA512SUMS
  )
  chmod 600 "$INSTALL_DIR"/*.ign "$INSTALL_DIR/SHA512SUMS"

  IGNITION_BASE_URL="http://10.80.40.10:8080/${INFRA_ID}"
  IGNITION_SPEC_VERSION="$bootstrap_version"
  BOOTSTRAP_IGNITION_SHA512="$(sha512sum "$INSTALL_DIR/bootstrap.ign" | awk '{print $1}')"
  MASTER_IGNITION_SHA512="$(sha512sum "$INSTALL_DIR/master.ign" | awk '{print $1}')"
  WORKER_IGNITION_SHA512="$(sha512sum "$INSTALL_DIR/worker.ign" | awk '{print $1}')"
  ASSET_GENERATED_AT="$(date -Iseconds)"
  ASSET_GENERATED_EPOCH="$(date +%s)"
  phase6_write_cluster_env
elif [[ -s "$INSTALL_DIR/bootstrap.ign" && -s "$INSTALL_DIR/master.ign" && -s "$INSTALL_DIR/worker.ign" ]]; then
  printf 'Generated Ignition already exists; validating and restaging the same fresh asset set.\n'
else
  phase6_error 'Neither install-config.yaml nor a complete generated Ignition set exists. Run scripts/06-01-prepare-openshift-install.sh again.'
fi

phase6_require_complete_assets
phase6_assert_assets_fresh
(
  cd "$INSTALL_DIR"
  sha512sum -c SHA512SUMS
)

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/bootstrap-edge.yml"

ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
  -i "$ANSIBLE_DIR/inventory/hosts.yml" \
  "$ANSIBLE_DIR/ignition.yml" \
  -e "ignition_source_dir=$INSTALL_DIR" \
  -e "ignition_infra_id=$INFRA_ID"

printf '\nIgnition generation and private HTTP staging PASSED.\n'
printf 'Infrastructure ID: %s\n' "$INFRA_ID"
printf 'Private base URL: %s\n' "$IGNITION_BASE_URL"
printf 'Generated at: %s\n' "$ASSET_GENERATED_AT"
printf 'Full Ignition content remains outside the repository and Terraform state.\n'
printf 'Next: bash scripts/06-05-validate-cluster-prerequisites.sh\n'
