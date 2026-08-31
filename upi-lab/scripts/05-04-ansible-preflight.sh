#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

for command_name in ansible ansible-playbook ansible-galaxy ssh ssh-keygen ssh-add; do
  command -v "$command_name" >/dev/null || {
    printf 'ERROR: Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

SSH_PRIVATE_KEY="$HOME/.ssh/openshift_upi_lab"
SSH_PUBLIC_KEY="$SSH_PRIVATE_KEY.pub"

[[ -s "$SSH_PRIVATE_KEY" ]] || {
  printf 'ERROR: Missing SSH private key: %s\n' "$SSH_PRIVATE_KEY" >&2
  exit 1
}
[[ -s "$SSH_PUBLIC_KEY" ]] || {
  printf 'ERROR: Missing SSH public key: %s\n' "$SSH_PUBLIC_KEY" >&2
  exit 1
}

if ! ssh-keygen -y -P '' -f "$SSH_PRIVATE_KEY" >/dev/null 2>&1; then
  if [[ -z ${SSH_AUTH_SOCK:-} ]] ||
     ! ssh-add -T "$SSH_PUBLIC_KEY" >/dev/null 2>&1; then
    printf 'ERROR: The passphrase-protected SSH key is not available through ssh-agent.\n' >&2
    printf 'Run chapter 05 section 8 to start ssh-agent and add %s.\n' "$SSH_PRIVATE_KEY" >&2
    exit 1
  fi
fi

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
printf 'Next: bash scripts/05-05-apply-infrastructure-services.sh\n'
