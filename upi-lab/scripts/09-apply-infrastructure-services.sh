#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
CLUSTER_STAGE_FILE="${CLUSTER_STAGE_FILE:-$HOME/.config/openshift-upi-lab/cluster-stage}"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

if [[ -z ${REGISTRY_PASSWORD:-} || ${#REGISTRY_PASSWORD} -lt 16 ]]; then
  printf 'ERROR: Set REGISTRY_PASSWORD to at least 16 characters.\n' >&2
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
else
  printf 'Apply cancelled.\n'
fi
