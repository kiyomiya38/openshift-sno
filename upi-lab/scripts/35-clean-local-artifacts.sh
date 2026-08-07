#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$REPO_DIR/terraform"
CONFIG_ROOT="${CONFIG_ROOT:-$HOME/.config/openshift-upi-lab}"
ASSET_ROOT="${ASSET_ROOT:-$HOME/.local/share/openshift-upi-lab}"
CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/openshift-upi-lab}"
CLEANUP_MARKER_FILE="${CLEANUP_MARKER_FILE:-$CONFIG_ROOT/cleanup-validated.json}"
ARCHIVE_PARENT="${ARCHIVE_PARENT:-$HOME/.local/share/openshift-upi-lab-cleanup-archive}"
# shellcheck source=lib/safety-common.sh
source "$SCRIPT_DIR/lib/safety-common.sh"

mode=preview
include_pki=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/35-clean-local-artifacts.sh
  bash scripts/35-clean-local-artifacts.sh --archive [--include-pki]
  bash scripts/35-clean-local-artifacts.sh --delete [--include-pki]

The default is a read-only preview. --archive moves generated artifacts to a
private directory outside the repository. --delete permanently removes them.
PKI, the SSH key, Pull Secret, and expected-account-id are retained unless
--include-pki is explicitly specified; SSH and Pull Secret are always retained.
EOF
}

while (($# > 0)); do
  case "$1" in
    --archive)
      [[ "$mode" == preview ]] || lab_safety_error 'Specify only one of --archive or --delete.'
      mode=archive
      ;;
    --delete)
      [[ "$mode" == preview ]] || lab_safety_error 'Specify only one of --archive or --delete.'
      mode=delete
      ;;
    --include-pki)
      include_pki=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      lab_safety_error "Unknown argument: $1"
      ;;
  esac
  shift
done

for command_name in flock jq realpath terraform; do
  command -v "$command_name" >/dev/null 2>&1 \
    || lab_safety_error "Required command is not installed: $command_name"
done

home_real="$(realpath -m -- "$HOME")"
config_root_real="$(realpath -m -- "$CONFIG_ROOT")"
asset_root_real="$(realpath -m -- "$ASSET_ROOT")"
cache_root_real="$(realpath -m -- "$CACHE_ROOT")"
archive_parent_real="$(realpath -m -- "$ARCHIVE_PARENT")"
for scoped_root in "$config_root_real" "$asset_root_real" "$cache_root_real" "$archive_parent_real"; do
  [[ "$scoped_root" == "$home_real"/* && "$scoped_root" != "$home_real" && "$scoped_root" != / ]] \
    || lab_safety_error "Local cleanup root must be a strict child of HOME: $scoped_root"
done
[[ "$(basename -- "$config_root_real")" == openshift-upi-lab \
    && "$(basename -- "$asset_root_real")" == openshift-upi-lab \
    && "$(basename -- "$cache_root_real")" == openshift-upi-lab \
    && "$(basename -- "$archive_parent_real")" == openshift-upi-lab-cleanup-archive ]] \
  || lab_safety_error 'Local cleanup roots do not have the expected lab-specific basenames.'
[[ "$(realpath -m -- "$CLEANUP_MARKER_FILE")" == "$config_root_real/cleanup-validated.json" ]] \
  || lab_safety_error 'CLEANUP_MARKER_FILE must remain inside the fixed lab configuration directory.'

[[ -s "$CLEANUP_MARKER_FILE" ]] \
  || lab_safety_error "Cleanup validation marker is missing: $CLEANUP_MARKER_FILE. Run scripts/14-validate-cleanup.sh."
lab_assert_default_workspace "$TERRAFORM_DIR"
lab_assert_no_recovery_or_active_test
[[ ! -e "$TERRAFORM_DIR/destroy.tfplan" && ! -e "$TERRAFORM_DIR/destroy.tfplan.meta" ]] \
  || lab_safety_error 'A destroy Plan or guard metadata remains. Complete or explicitly discard it first.'

marker_account="$(jq -er '.account_id | select(test("^[0-9]{12}$"))' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has an invalid account ID.'
marker_region="$(jq -er '.region' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has no region.'
marker_workspace="$(jq -er '.workspace' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has no workspace.'
marker_lineage="$(jq -er '.state_lineage' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has no state lineage.'
marker_serial="$(jq -er '.state_serial' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has no state serial.'
marker_managed_count="$(jq -er '.managed_resource_count' "$CLEANUP_MARKER_FILE")" \
  || lab_safety_error 'Cleanup marker has no managed-resource count.'

[[ "$marker_region" == ap-northeast-3 && "$marker_workspace" == default \
    && "$marker_managed_count" == 0 ]] \
  || lab_safety_error 'Cleanup marker is not for the fixed lab region, default workspace, and empty state.'

if explicit_account="$(lab_resolve_expected_account_id strict "$TERRAFORM_DIR" '' 2>/dev/null)"; then
  [[ "$explicit_account" == "$marker_account" ]] \
    || lab_safety_error 'Cleanup marker account differs from the independently registered account.'
else
  printf 'WARN: No external account registration remains; relying on the post-cleanup validation marker.\n' >&2
fi

if current_state="$(terraform -chdir="$TERRAFORM_DIR" state pull 2>/dev/null)"; then
  current_managed_count="$(jq -r '[.resources[]? | select(.mode == "managed")] | length' <<<"$current_state")"
  current_lineage="$(jq -r '.lineage // "absent"' <<<"$current_state")"
  current_serial="$(jq -r '.serial // 0' <<<"$current_state")"
else
  current_managed_count=0
  current_lineage=absent
  current_serial=0
fi
[[ "$current_managed_count" == 0 ]] \
  || lab_safety_error "Terraform state contains $current_managed_count managed resources."
[[ "$current_lineage" == "$marker_lineage" && "$current_serial" == "$marker_serial" ]] \
  || lab_safety_error 'Terraform state changed after AWS cleanup validation. Run scripts/14 again.'

declare -a target_sources=()
declare -a target_relatives=()

add_target() {
  local source_path="$1"
  local relative_path="$2"
  [[ -e "$source_path" || -L "$source_path" ]] || return 0
  target_sources+=("$source_path")
  target_relatives+=("$relative_path")
}

add_target "$TERRAFORM_DIR/.terraform" 'repository/terraform/.terraform'
add_target "$TERRAFORM_DIR/terraform.tfstate" 'repository/terraform/terraform.tfstate'
add_target "$TERRAFORM_DIR/terraform.tfstate.backup" 'repository/terraform/terraform.tfstate.backup'

shopt -s nullglob
for generated_plan in "$TERRAFORM_DIR"/*.tfplan "$TERRAFORM_DIR"/*.tfplan.meta "$TERRAFORM_DIR"/*.tfplan.pending; do
  add_target "$generated_plan" "repository/terraform/$(basename -- "$generated_plan")"
done
shopt -u nullglob

for generated_root in logs artifacts; do
  [[ -d "$REPO_DIR/$generated_root" ]] || continue
  shopt -s nullglob dotglob
  for generated_entry in "$REPO_DIR/$generated_root"/*; do
    [[ "$(basename -- "$generated_entry")" == .gitkeep ]] && continue
    add_target "$generated_entry" "repository/$generated_root/$(basename -- "$generated_entry")"
  done
  shopt -u nullglob dotglob
done
add_target "$ASSET_ROOT" 'home/local-share/openshift-upi-lab'
add_target "$CONFIG_ROOT/client-config" 'home/config/client-config'
add_target "$CONFIG_ROOT/cluster-stage" 'home/config/cluster-stage'
add_target "$CONFIG_ROOT/destroy-applied.json" 'home/config/destroy-applied.json'
add_target "$CONFIG_ROOT/haproxy-failover.lock" 'home/config/haproxy-failover.lock'
add_target "$CONFIG_ROOT/worker-reboot.lock" 'home/config/worker-reboot.lock'
add_target "$CONFIG_ROOT/worker-reboot-results" 'home/config/worker-reboot-results'
add_target "$CACHE_ROOT" 'home/cache/openshift-upi-lab'
if "$include_pki"; then
  add_target "$CONFIG_ROOT/pki" 'home/config/pki'
fi
# The cleanup marker is deliberately last. If an archive or deletion is
# interrupted, a remaining marker forces the operator to inspect and resume
# the explicitly scoped cleanup instead of treating it as complete.
add_target "$CLEANUP_MARKER_FILE" 'home/config/cleanup-validated.json'

if ((${#target_sources[@]} == 0)); then
  printf 'No scoped local artifacts remain.\n'
  exit 0
fi

repo_real="$(realpath -m -- "$REPO_DIR")"
terraform_real="$(realpath -m -- "$TERRAFORM_DIR")"
config_real="$(realpath -m -- "$CONFIG_ROOT")"
asset_real="$(realpath -m -- "$ASSET_ROOT")"
cache_real="$(realpath -m -- "$CACHE_ROOT")"

printf 'Validated AWS cleanup marker account: %s\n' "$marker_account"
printf 'The following explicitly scoped local artifacts are selected:\n'
for index in "${!target_sources[@]}"; do
  source_path="${target_sources[$index]}"
  resolved_path="$(realpath -m -- "$source_path")"
  case "$resolved_path" in
    "$terraform_real"/.terraform | "$terraform_real"/terraform.tfstate | \
    "$terraform_real"/terraform.tfstate.backup | "$terraform_real"/*.tfplan | \
    "$terraform_real"/*.tfplan.meta | "$terraform_real"/*.tfplan.pending | \
    "$repo_real"/logs/* | "$repo_real"/artifacts/* | "$asset_real" | "$cache_real" | \
    "$config_real"/client-config | "$config_real"/cluster-stage | \
    "$config_real"/destroy-applied.json | "$config_real"/haproxy-failover.lock | \
    "$config_real"/worker-reboot.lock | "$config_real"/worker-reboot-results | \
    "$config_real"/cleanup-validated.json | "$config_real"/pki)
      ;;
    *)
      lab_safety_error "Refusing an artifact outside the explicit allowlist: $resolved_path"
      ;;
  esac
  printf '  %s\n' "$source_path"
done

printf '\nRetained by default:\n'
printf '  %s\n' "$LAB_EXPECTED_ACCOUNT_FILE"
printf '  %s\n' "$HOME/.ssh/openshift_upi_lab" "$HOME/.ssh/openshift_upi_lab.pub"
printf '  %s\n' "$HOME/.config/openshift/pull-secret.json"
if ! "$include_pki"; then
  printf '  %s (use --include-pki to include it)\n' "$CONFIG_ROOT/pki"
fi

if [[ "$mode" == preview ]]; then
  printf '\nPreview only; no files were changed.\n'
  printf 'Use --archive for recoverable isolation or --delete for permanent removal.\n'
  exit 0
fi

if [[ "$mode" == archive ]]; then
  archive_dir="$ARCHIVE_PARENT/$(date +%Y%m%d-%H%M%S)"
  [[ ! -e "$archive_dir" ]] || lab_safety_error "Archive destination already exists: $archive_dir"
  printf '\nArchive destination: %s\n' "$archive_dir"
  read -r -p 'Type ARCHIVE-LOCAL-LAB-ARTIFACTS to continue: ' CONFIRM
  [[ "$CONFIRM" == ARCHIVE-LOCAL-LAB-ARTIFACTS ]] || {
    printf 'Local cleanup cancelled.\n'
    exit 0
  }
  install -d -m 700 "$archive_dir"
  trap 'printf "ERROR: Archive was interrupted. Completed moves remain under %s; rerun preview before continuing.\n" "$archive_dir" >&2' ERR
  for index in "${!target_sources[@]}"; do
    destination="$archive_dir/${target_relatives[$index]}"
    install -d -m 700 "$(dirname -- "$destination")"
    mv -- "${target_sources[$index]}" "$destination"
  done
  trap - ERR
  printf 'Local artifacts were isolated at %s with directory mode 700.\n' "$archive_dir"
else
  printf '\nWARNING: --delete permanently removes Terraform state/history, kubeconfig, Ignition, logs, and exported VPN configuration.\n'
  "$include_pki" && printf 'WARNING: Client VPN CA, server key, and client key are also selected.\n'
  read -r -p 'Type DELETE-LOCAL-LAB-ARTIFACTS to continue: ' CONFIRM
  [[ "$CONFIRM" == DELETE-LOCAL-LAB-ARTIFACTS ]] || {
    printf 'Local cleanup cancelled.\n'
    exit 0
  }
  trap 'printf "ERROR: Deletion was interrupted. The validation marker is deleted last; rerun this script to inspect remaining targets.\n" >&2' ERR
  for source_path in "${target_sources[@]}"; do
    rm -rf -- "$source_path"
  done
  trap - ERR
  printf 'Selected local lab artifacts were permanently removed.\n'
fi

printf 'If the .ovpn profile was imported into the Windows AWS VPN Client, remove that profile manually.\n'
printf 'The AWS profile and IAM access key are not owned by this lab cleanup and were retained.\n'
