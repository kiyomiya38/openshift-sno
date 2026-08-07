#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

PLAN_FILE="$TERRAFORM_DIR/bootstrap-removal.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_require_file "$INSTALL_DIR/bootstrap-complete.ok"
[[ -s "$CLUSTER_STAGE_FILE" && "$(<"$CLUSTER_STAGE_FILE")" == steady ]] \
  || phase6_error 'HAProxy/DNS steady-state marker is missing. Run scripts/24 first.'

phase6_export_base_terraform_vars
phase6_export_asset_terraform_vars
phase6_set_terraform_stage true true false

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PLAN_FILE"

changes_json="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -c '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | {address,actions:.change.actions}]')"

printf '\nManaged resource actions:\n'
jq -r '.[] | [.address, (.actions | join(","))] | @tsv' <<<"$changes_json"

phase6_assert_bootstrap_removal_plan "$changes_json"

printf 'Bootstrap removal plan validation PASSED.\n'
printf 'Expected summary: 0 to add, 0 to change, 1 to destroy.\n'
printf 'Saved plan: %s\n' "$PLAN_FILE"
printf 'Next: bash scripts/26-apply-bootstrap-removal.sh\n'
