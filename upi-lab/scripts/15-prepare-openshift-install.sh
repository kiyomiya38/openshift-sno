#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

PULL_SECRET_FILE="${PULL_SECRET_FILE:-$HOME/.config/openshift/pull-secret.json}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/openshift_upi_lab.pub}"

for command_name in ansible-playbook aws jq openshift-install terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context
phase6_require_file "$PULL_SECRET_FILE"
phase6_require_file "$SSH_PUBLIC_KEY_FILE"
jq -e 'type == "object" and (.auths | type == "object")' "$PULL_SECRET_FILE" >/dev/null \
  || phase6_error "Pull Secret is not valid JSON with an auths object: $PULL_SECRET_FILE"

if terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null | grep -q '^aws_instance\.openshift\['; then
  phase6_error 'OpenShift EC2 instances already exist in Terraform state. Do not replace active cluster assets.'
fi

OPENSHIFT_INSTALL_VERSION="$(openshift-install version | awk 'NR == 1 {print $2}')"
[[ "$EXPECTED_OPENSHIFT_VERSION" =~ ^4\.21\.[0-9]+$ ]] \
  || phase6_error "EXPECTED_OPENSHIFT_VERSION must be an OpenShift 4.21 patch release, found $EXPECTED_OPENSHIFT_VERSION."
if [[ "$EXPECTED_OPENSHIFT_VERSION" != "$PHASE6_VERIFIED_OPENSHIFT_VERSION" ]]; then
  printf 'WARN: OpenShift %s is an explicit override; repeat the full validation suite (verified release: %s).\n' \
    "$EXPECTED_OPENSHIFT_VERSION" "$PHASE6_VERIFIED_OPENSHIFT_VERSION" >&2
fi
[[ "$OPENSHIFT_INSTALL_VERSION" == "$EXPECTED_OPENSHIFT_VERSION" ]] \
  || phase6_error "Expected openshift-install $EXPECTED_OPENSHIFT_VERSION, found $OPENSHIFT_INSTALL_VERSION."

RHCOS_AMI_ID="$(openshift-install coreos print-stream-json |
  jq -er --arg region "$AWS_REGION_NAME" '.architectures.x86_64.images.aws.regions[$region].image')"

ami_json="$(aws ec2 describe-images \
  --profile "$AWS_PROFILE_NAME" \
  --region "$AWS_REGION_NAME" \
  --image-ids "$RHCOS_AMI_ID" \
  --query 'Images[0]' \
  --output json)"

jq -e '
  .OwnerId == "531415883065" and
  .State == "available" and
  .Architecture == "x86_64" and
  .RootDeviceType == "ebs" and
  .VirtualizationType == "hvm"
' <<<"$ami_json" >/dev/null || phase6_error "The installer-selected RHCOS AMI failed validation: $RHCOS_AMI_ID"

install -d -m 700 "$ASSET_ROOT"
if [[ -d "$INSTALL_DIR" ]] && find "$INSTALL_DIR" -mindepth 1 -print -quit | grep -q .; then
  archive_dir="${INSTALL_DIR}.archive.$(date +%Y%m%d-%H%M%S)"
  mv -- "$INSTALL_DIR" "$archive_dir"
  printf 'Archived the previous install directory: %s\n' "$archive_dir"
elif [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
  phase6_error "INSTALL_DIR exists but is not a directory: $INSTALL_DIR"
fi
install -d -m 700 "$INSTALL_DIR"
umask 077

pull_secret="$(jq -c . "$PULL_SECRET_FILE")"
ssh_public_key="$(<"$SSH_PUBLIC_KEY_FILE")"
no_proxy='127.0.0.1,localhost,.svc,.cluster.local,10.80.0.0/16,10.128.0.0/14,172.30.0.0/16,169.254.169.254,ocp.lab.k8study.com,.ocp.lab.k8study.com,.compute.internal'

jq -n \
  --arg pull_secret "$pull_secret" \
  --arg ssh_public_key "$ssh_public_key" \
  --arg no_proxy "$no_proxy" \
  '{
    apiVersion: "v1",
    baseDomain: "lab.k8study.com",
    metadata: {name: "ocp"},
    compute: [{
      architecture: "amd64",
      hyperthreading: "Enabled",
      name: "worker",
      platform: {},
      replicas: 0
    }],
    controlPlane: {
      architecture: "amd64",
      hyperthreading: "Enabled",
      name: "master",
      platform: {},
      replicas: 3
    },
    networking: {
      networkType: "OVNKubernetes",
      machineNetwork: [{cidr: "10.80.0.0/16"}],
      clusterNetwork: [{cidr: "10.128.0.0/14", hostPrefix: 23}],
      serviceNetwork: ["172.30.0.0/16"]
    },
    platform: {none: {}},
    fips: false,
    proxy: {
      httpProxy: "http://10.80.40.31:3128",
      httpsProxy: "http://10.80.40.31:3128",
      noProxy: $no_proxy
    },
    pullSecret: $pull_secret,
    sshKey: $ssh_public_key
  }' >"$INSTALL_DIR/install-config.yaml"

chmod 600 "$INSTALL_DIR/install-config.yaml"
install -m 600 "$INSTALL_DIR/install-config.yaml" "$ASSET_ROOT/install-config.backup.yaml"

INSTALL_CONFIG_CREATED_AT="$(date -Iseconds)"
INFRA_ID=''
IGNITION_BASE_URL=''
IGNITION_SPEC_VERSION=''
BOOTSTRAP_IGNITION_SHA512=''
MASTER_IGNITION_SHA512=''
WORKER_IGNITION_SHA512=''
ASSET_GENERATED_AT=''
ASSET_GENERATED_EPOCH=''
phase6_write_cluster_env

install -d -m 700 "$(dirname -- "$CLUSTER_STAGE_FILE")"
printf 'bootstrap\n' >"$CLUSTER_STAGE_FILE"
chmod 600 "$CLUSTER_STAGE_FILE"

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate

for playbook in \
  bootstrap-edge.yml \
  ignition.yml \
  pre-bootstrap-removal.yml \
  steady-state.yml \
  validate-steady-state.yml \
  stop-ignition.yml
do
  ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" ansible-playbook \
    -i "$ANSIBLE_DIR/inventory/hosts.yml" \
    --syntax-check "$ANSIBLE_DIR/$playbook"
done

printf 'OpenShift install input preparation PASSED.\n'
printf 'Installer version: %s\n' "$OPENSHIFT_INSTALL_VERSION"
printf 'Validated RHCOS AMI: %s (%s)\n' "$RHCOS_AMI_ID" "$(jq -r .Name <<<"$ami_json")"
printf 'Install config: %s\n' "$INSTALL_DIR/install-config.yaml"
printf 'No Manifest, Ignition, or OpenShift EC2 instance was created.\n'
printf 'Next: bash scripts/16-plan-cluster-prerequisites.sh\n'
