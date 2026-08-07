#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

for command_name in ansible ansible-playbook ansible-galaxy ssh; do
  command -v "$command_name" >/dev/null || {
    printf 'ERROR: Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

[[ -s "$HOME/.ssh/openshift_upi_lab" ]] || {
  printf 'ERROR: Missing SSH private key: %s\n' "$HOME/.ssh/openshift_upi_lab" >&2
  exit 1
}

if [[ -z ${REGISTRY_PASSWORD:-} || ${#REGISTRY_PASSWORD} -lt 16 ]]; then
  printf 'ERROR: Set REGISTRY_PASSWORD to at least 16 characters.\n' >&2
  exit 1
fi

cd "$ANSIBLE_DIR"
ansible-inventory --graph
for playbook in \
  site.yml \
  validate.yml \
  bootstrap-edge.yml \
  ignition.yml \
  pre-bootstrap-removal.yml \
  steady-state.yml \
  validate-steady-state.yml \
  stop-ignition.yml
do
  ansible-playbook --syntax-check "$playbook"
done
ansible all -m ansible.builtin.ping

printf '\nAnsible preflight PASSED. No remote configuration was changed.\n'
