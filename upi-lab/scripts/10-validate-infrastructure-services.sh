#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

if [[ -z ${REGISTRY_PASSWORD:-} || ${#REGISTRY_PASSWORD} -lt 16 ]]; then
  printf 'ERROR: Set REGISTRY_PASSWORD to the same value used during Apply.\n' >&2
  exit 1
fi

cd "$ANSIBLE_DIR"
ansible-playbook validate.yml
printf '\nInfrastructure services validation PASSED.\n'
