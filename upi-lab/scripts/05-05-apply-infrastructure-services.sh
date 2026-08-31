#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
CLUSTER_STAGE_FILE="${CLUSTER_STAGE_FILE:-$HOME/.config/openshift-upi-lab/cluster-stage}"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

if [[ -z ${REGISTRY_PASSWORD:-} ]]; then
  printf 'ERROR: REGISTRY_PASSWORD is unset or was not exported to this process.\n' >&2
  printf 'Run chapter 05 section 9 in the current WSL shell.\n' >&2
  exit 1
elif (( ${#REGISTRY_PASSWORD} < 16 )); then
  printf 'ERROR: REGISTRY_PASSWORD has %d characters; at least 16 are required.\n' \
    "${#REGISTRY_PASSWORD}" >&2
  exit 1
fi

cd "$ANSIBLE_DIR"
ansible-playbook --syntax-check site.yml

cluster_stage=bootstrap
if [[ -s "$CLUSTER_STAGE_FILE" && "$(<"$CLUSTER_STAGE_FILE")" == steady ]]; then
  cluster_stage=steady
fi
printf 'HAProxy/DNS cluster stage: %s\n' "$cluster_stage"

read -r -p 'Type APPLY-ANSIBLE-SERVICES to continue: ' CONFIRM
if [[ "$CONFIRM" == 'APPLY-ANSIBLE-SERVICES' ]]; then
  ansible-playbook site.yml -e "cluster_stage=$cluster_stage"
  printf 'Next: bash scripts/05-06-validate-infrastructure-services.sh\n'
else
  printf 'Apply cancelled.\n'
fi
