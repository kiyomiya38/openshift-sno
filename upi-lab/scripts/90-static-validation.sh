#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$LAB_ROOT/ansible"
TERRAFORM_DIR="$LAB_ROOT/terraform"
failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
}

printf '=== Bash ===\n'
mapfile -d '' shell_files < <(find "$SCRIPT_DIR" -type f -name '*.sh' -print0 | sort -z)
if ((${#shell_files[@]} == 0)); then
  fail 'No Bash scripts were found.'
elif printf '%s\0' "${shell_files[@]}" | xargs -0 -n1 bash -n; then
  pass "Bash syntax is valid for ${#shell_files[@]} script(s)."
else
  fail 'Bash syntax validation failed.'
fi

if command -v shellcheck >/dev/null 2>&1; then
  # SC2034 is suppressed because phase6 variables are serialized indirectly
  # by write_env_file; ShellCheck cannot trace those name-based references.
  if shellcheck --severity=warning --exclude=SC2034 -x "${shell_files[@]}"; then
    pass 'ShellCheck passed.'
  else
    fail 'ShellCheck failed.'
  fi
else
  skip 'shellcheck is not installed.'
fi

printf '\n=== Terraform ===\n'
if command -v terraform >/dev/null 2>&1; then
  if terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive -diff; then
    pass 'Terraform formatting check passed.'
  else
    fail 'Terraform formatting check failed.'
  fi

  if [[ -d "$TERRAFORM_DIR/.terraform/providers" ]]; then
    if terraform -chdir="$TERRAFORM_DIR" validate -no-color; then
      pass 'Terraform validation passed using the locally installed provider.'
    else
      fail 'Terraform validation failed.'
    fi
  else
    skip 'Terraform provider is not installed; run terraform init -backend=false, then rerun this check.'
  fi
else
  skip 'terraform is not installed.'
fi

printf '\n=== Ansible ===\n'
if command -v ansible-playbook >/dev/null 2>&1 && command -v ansible-galaxy >/dev/null 2>&1; then
  collection_list="$(ansible-galaxy collection list 2>/dev/null || true)"
  if grep -Eq '^ansible\.posix[[:space:]]+2\.2\.2([[:space:]]|$)' <<<"$collection_list" \
    && grep -Eq '^community\.general[[:space:]]+13\.2\.0([[:space:]]|$)' <<<"$collection_list"; then
    pass 'Pinned Ansible Collections are installed.'
  else
    fail 'Pinned Ansible Collections are missing; install ansible/requirements.yml.'
  fi

  mapfile -d '' playbooks < <(find "$ANSIBLE_DIR" -maxdepth 1 -type f -name '*.yml' ! -name 'requirements.yml' -print0 | sort -z)
  ansible_failed=0
  for playbook in "${playbooks[@]}"; do
    if ! ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg" \
      REGISTRY_PASSWORD='static-validation-only-password' \
      ansible-playbook --syntax-check "$playbook" >/dev/null; then
      printf 'Ansible syntax failed: %s\n' "${playbook#"$LAB_ROOT/"}" >&2
      ansible_failed=1
    fi
  done
  if ((ansible_failed == 0)); then
    pass "Ansible syntax is valid for ${#playbooks[@]} playbook(s)."
  else
    fail 'Ansible syntax validation failed.'
  fi

  if command -v ansible-lint >/dev/null 2>&1; then
    if (cd "$ANSIBLE_DIR" && ansible-lint --offline .); then
      pass 'ansible-lint passed.'
    else
      fail 'ansible-lint failed.'
    fi
  else
    skip 'ansible-lint is not installed.'
  fi
else
  skip 'ansible-playbook or ansible-galaxy is not installed.'
fi

if command -v tflint >/dev/null 2>&1; then
  if tflint --chdir="$TERRAFORM_DIR" --no-color; then
    pass 'TFLint passed.'
  else
    fail 'TFLint failed.'
  fi
else
  skip 'tflint is not installed.'
fi

printf '\n=== Documentation and release metadata ===\n'
if command -v python3 >/dev/null 2>&1; then
  if python3 "$SCRIPT_DIR/90-validate-diagrams.py"; then
    pass 'Committed architecture diagram sources and renderings are valid.'
  else
    fail 'Architecture diagram validation failed.'
  fi

  if python3 "$SCRIPT_DIR/90-validate-markdown.py"; then
    pass 'Markdown structure and local links are valid.'
  else
    fail 'Markdown validation failed.'
  fi

  if python3 -c 'import yaml' >/dev/null 2>&1; then
    if python3 "$SCRIPT_DIR/90-validate-yaml.py"; then
      pass 'Non-Ansible YAML syntax and unique-key checks passed.'
    else
      fail 'Non-Ansible YAML validation failed.'
    fi
  else
    skip 'PyYAML is not installed; non-Ansible YAML validation was skipped.'
  fi
else
  fail 'python3 is required for Markdown validation.'
fi

for required_file in \
  "$LAB_ROOT/LICENSE" \
  "$LAB_ROOT/SECURITY.md" \
  "$LAB_ROOT/THIRD_PARTY_NOTICES.md" \
  "$LAB_ROOT/licenses/Apache-2.0.txt" \
  "$LAB_ROOT/configs/tested-versions.yaml" \
  "$TERRAFORM_DIR/.terraform.lock.hcl"; do
  if [[ -s "$required_file" ]]; then
    pass "Release metadata exists: ${required_file#"$LAB_ROOT/"}"
  else
    fail "Required release metadata is missing: ${required_file#"$LAB_ROOT/"}"
  fi
done

printf '\n=== Static validation result ===\n'
printf 'Failures: %d\n' "$failures"
if ((failures > 0)); then
  exit 1
fi

printf 'Static validation PASSED. No AWS API call or infrastructure change was made.\n'
