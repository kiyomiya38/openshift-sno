#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

PLAN_FILE="$TERRAFORM_DIR/cluster-nodes.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_export_base_terraform_vars
phase6_export_asset_terraform_vars
phase6_assert_assets_fresh
phase6_set_terraform_stage true true true

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PLAN_FILE"

changes_json="$(terraform -chdir="$TERRAFORM_DIR" show -json "$PLAN_FILE" |
  jq -c '[.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"]) | {address,actions:.change.actions}]')"

printf '\nManaged resource actions:\n'
jq -r '.[] | [.address, (.actions | join(","))] | @tsv' <<<"$changes_json"

phase6_assert_node_plan "$changes_json"

printf 'Cluster node plan validation PASSED.\n'
printf 'Expected summary: 7 to add, 0 to change, 0 to destroy.\n'
printf 'Bootstrap, three control-plane nodes, and three workers will start in this stage.\n'
printf 'Saved plan: %s\n' "$PLAN_FILE"
printf 'Next: bash scripts/21-apply-cluster-nodes.sh\n'
