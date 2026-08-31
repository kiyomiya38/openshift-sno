#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd -- "$SCRIPT_DIR/../ansible" && pwd)"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
[[ -x "$HOME/.local/bin/ansible" ]] && export PATH="$HOME/.local/bin:$PATH"

if [[ -z ${REGISTRY_PASSWORD:-} ]]; then
  printf 'ERROR: REGISTRY_PASSWORD is unset or was not exported to this process.\n' >&2
  printf 'Set it to the same value used during Apply, following chapter 05 section 9.\n' >&2
  exit 1
elif (( ${#REGISTRY_PASSWORD} < 16 )); then
  printf 'ERROR: REGISTRY_PASSWORD has %d characters; at least 16 are required.\n' \
    "${#REGISTRY_PASSWORD}" >&2
  exit 1
fi

cd "$ANSIBLE_DIR"
ansible-playbook validate.yml
printf '\nInfrastructure services validation PASSED.\n'
printf 'Next: bash scripts/05-07-plan-client-vpn-dns.sh\n'
