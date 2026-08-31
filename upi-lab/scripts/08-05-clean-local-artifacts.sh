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
archive_id=''

usage() {
  cat <<'EOF'
Usage:
  bash scripts/08-05-clean-local-artifacts.sh
  bash scripts/08-05-clean-local-artifacts.sh --archive [--include-pki]
  bash scripts/08-05-clean-local-artifacts.sh --delete [--include-pki]
  bash scripts/08-05-clean-local-artifacts.sh --archive-pki ARCHIVE_ID
  bash scripts/08-05-clean-local-artifacts.sh --delete-archive ARCHIVE_ID

The default is a read-only preview. --archive moves generated artifacts to a
private directory outside the repository. --delete permanently removes them.
PKI, the SSH key, Pull Secret, and expected-account-id are retained unless
--include-pki is explicitly specified; SSH and Pull Secret are always retained.
--archive-pki moves retained PKI into one archive previously created by this
script. --delete-archive permanently removes one validated existing archive.
EOF
}

while (($# > 0)); do
  case "$1" in
    --archive)
      [[ "$mode" == preview ]] || lab_safety_error 'Specify only one cleanup mode.'
      mode=archive
      ;;
    --delete)
      [[ "$mode" == preview ]] || lab_safety_error 'Specify only one cleanup mode.'
      mode=delete
      ;;
    --archive-pki | --delete-archive)
      [[ "$mode" == preview ]] || lab_safety_error 'Specify only one cleanup mode.'
      mode="${1#--}"
      shift
      (($# > 0)) || lab_safety_error "--$mode requires an archive ID in YYYYMMDD-HHMMSS format."
      archive_id="$1"
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

if [[ "$mode" == archive-pki || "$mode" == delete-archive ]]; then
  ! "$include_pki" \
    || lab_safety_error "--include-pki cannot be combined with --$mode."
  required_commands=(flock jq realpath stat)
else
  required_commands=(flock jq realpath terraform)
fi
for command_name in "${required_commands[@]}"; do
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

validate_existing_archive() {
  local selected_id="$1"
  local selected_path marker_path marker_owner

  [[ "$selected_id" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
    || lab_safety_error 'Archive ID must use the exact YYYYMMDD-HHMMSS format.'
  [[ -d "$archive_parent_real" && ! -L "$archive_parent_real" ]] \
    || lab_safety_error "Archive parent is missing or unsafe: $archive_parent_real"

  selected_path="$archive_parent_real/$selected_id"
  [[ -d "$selected_path" && ! -L "$selected_path" ]] \
    || lab_safety_error "The selected archive is missing or is not a regular directory: $selected_path"
  archive_target_real="$(realpath -e -- "$selected_path")"
  [[ "$archive_target_real" == "$selected_path" \
      && "$(dirname -- "$archive_target_real")" == "$archive_parent_real" ]] \
    || lab_safety_error 'The selected archive does not resolve to the expected direct child path.'
  [[ "$(stat -c '%u' -- "$archive_target_real")" == "$(id -u)" ]] \
    || lab_safety_error 'The selected archive is not owned by the current user.'
  [[ "$(stat -c '%a' -- "$archive_target_real")" == 700 ]] \
    || lab_safety_error 'The selected archive directory mode must be 700.'

  marker_path="$archive_target_real/home/config/cleanup-validated.json"
  [[ -f "$marker_path" && ! -L "$marker_path" ]] \
    || lab_safety_error 'The selected archive has no regular cleanup-validation marker.'
  marker_owner="$(stat -c '%u' -- "$marker_path")"
  [[ "$marker_owner" == "$(id -u)" ]] \
    || lab_safety_error 'The archived cleanup marker is not owned by the current user.'

  archive_account="$(jq -er '.account_id | select(test("^[0-9]{12}$"))' "$marker_path")" \
    || lab_safety_error 'The archived cleanup marker has an invalid account ID.'
  archive_region="$(jq -er '.region' "$marker_path")" \
    || lab_safety_error 'The archived cleanup marker has no region.'
  archive_workspace="$(jq -er '.workspace' "$marker_path")" \
    || lab_safety_error 'The archived cleanup marker has no workspace.'
  archive_managed_count="$(jq -er '.managed_resource_count' "$marker_path")" \
    || lab_safety_error 'The archived cleanup marker has no managed-resource count.'
  archive_validated_at="$(jq -er '.validated_at' "$marker_path")" \
    || lab_safety_error 'The archived cleanup marker has no validation timestamp.'
  [[ "$archive_region" == ap-northeast-3 && "$archive_workspace" == default \
      && "$archive_managed_count" == 0 ]] \
    || lab_safety_error 'The archive is not for the fixed lab region, default workspace, and empty state.'

  expected_account="$(lab_resolve_expected_account_id strict "$TERRAFORM_DIR" '' 2>/dev/null)" \
    || lab_safety_error 'The independently registered account ID is required for archive maintenance.'
  [[ "$archive_account" == "$expected_account" ]] \
    || lab_safety_error 'The archive account differs from the independently registered account.'
}

if [[ "$mode" == archive-pki || "$mode" == delete-archive ]]; then
  validate_existing_archive "$archive_id"
  exec {archive_lock_fd}<"$archive_parent_real"
  flock -n "$archive_lock_fd" \
    || lab_safety_error 'Another local archive-maintenance operation is active.'

  printf 'Validated archived cleanup account: %s\n' "$archive_account"
  printf 'Cleanup validated at: %s\n' "$archive_validated_at"
  printf 'Selected archive: %s\n' "$archive_target_real"

  if [[ "$mode" == archive-pki ]]; then
    pki_source="$config_root_real/pki"
    pki_destination="$archive_target_real/home/config/pki"
    if [[ ! -e "$pki_source" && ! -L "$pki_source" ]]; then
      printf 'No retained Client VPN PKI remains at %s.\n' "$pki_source"
      exit 0
    fi
    [[ -d "$pki_source" && ! -L "$pki_source" \
        && "$(realpath -e -- "$pki_source")" == "$config_root_real/pki" ]] \
      || lab_safety_error 'The retained PKI path is not the fixed regular lab PKI directory.'
    [[ ! -e "$pki_destination" && ! -L "$pki_destination" ]] \
      || lab_safety_error 'The selected archive already contains a PKI destination.'

    printf 'Retained PKI source: %s\n' "$pki_source"
    printf 'PKI archive destination: %s\n' "$pki_destination"
    read -r -p "Type ARCHIVE-PKI-INTO-$archive_id to continue: " CONFIRM
    if [[ "$CONFIRM" == "ARCHIVE-PKI-INTO-$archive_id" ]]; then
      install -d -m 700 "$(dirname -- "$pki_destination")"
      mv -- "$pki_source" "$pki_destination"
      [[ ! -e "$pki_source" && -d "$pki_destination" ]] \
        || lab_safety_error 'PKI archive operation did not reach the expected final state.'
      printf 'Retained Client VPN PKI was added to the selected archive.\n'
    else
      printf 'PKI archive operation cancelled.\n'
    fi
    exit 0
  fi

  printf 'WARNING: This permanently removes the entire selected archive.\n'
  read -r -p "Type DELETE-LOCAL-LAB-ARCHIVE-$archive_id to continue: " CONFIRM
  if [[ "$CONFIRM" == "DELETE-LOCAL-LAB-ARCHIVE-$archive_id" ]]; then
    rm -rf --one-file-system -- "$archive_target_real"
    [[ ! -e "$archive_target_real" ]] \
      || lab_safety_error 'The selected archive still exists after removal.'
    printf 'Selected local lab archive was permanently removed.\n'
  else
    printf 'Archive removal cancelled.\n'
  fi
  exit 0
fi

if [[ ! -s "$CLEANUP_MARKER_FILE" ]]; then
  shopt -s nullglob
  archived_markers=("$ARCHIVE_PARENT"/*/home/config/cleanup-validated.json)
  shopt -u nullglob
  if ((${#archived_markers[@]} > 0)); then
    printf 'ERROR: Local artifacts were already archived, so the active cleanup marker is no longer present.\n' >&2
    printf 'Validated archive(s) found:\n' >&2
    for archived_marker_path in "${archived_markers[@]}"; do
      printf '  %s\n' "${archived_marker_path%/home/config/cleanup-validated.json}" >&2
    done
    printf 'Do not run the ordinary --delete or --include-pki modes after --archive.\n' >&2
    printf 'Use --archive-pki ARCHIVE_ID or --delete-archive ARCHIVE_ID as documented in chapter 08.\n' >&2
    exit 1
  fi
  lab_safety_error "Cleanup validation marker is missing: $CLEANUP_MARKER_FILE. Run scripts/08-04-validate-cleanup.sh."
fi
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

current_state="$(lab_pull_state_json_allow_absent "$TERRAFORM_DIR")"
if [[ -n "$current_state" ]]; then
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
  || lab_safety_error 'Terraform state changed after AWS cleanup validation. Run scripts/08-04-validate-cleanup.sh again.'

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
printf '  %s\n' "$CONFIG_ROOT/lab-root"
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
