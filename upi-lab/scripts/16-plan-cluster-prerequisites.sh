#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"

PLAN_FILE="$TERRAFORM_DIR/cluster-prerequisites.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_load_cluster_env
phase6_export_base_terraform_vars
phase6_set_terraform_stage true false false

terraform -chdir="$TERRAFORM_DIR" fmt -check -recursive
terraform -chdir="$TERRAFORM_DIR" validate
terraform -chdir="$TERRAFORM_DIR" plan -input=false -out="$PLAN_FILE"

changes_json="$(phase6_managed_plan_changes_json "$PLAN_FILE")"

printf '\nManaged resource actions:\n'
jq -r '.[] | [.address, (.actions | join(","))] | @tsv' <<<"$changes_json"

plan_kind="$(phase6_prerequisite_plan_kind "$changes_json")" \
  || phase6_error 'Plan does not exactly match an allowed Phase 6 prerequisite pass. Do not apply.'

case "$plan_kind" in
  prerequisites)
    printf 'Cluster prerequisite Plan validation PASSED.\n'
    printf 'Expected summary for a clean build: 13 to add, 0 to change, 0 to destroy.\n'
    printf 'The Installer-only Ignition Security Group was already attached in Phase 4.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    printf 'Next: bash scripts/17-apply-cluster-prerequisites.sh\n'
    ;;
  resources)
    printf 'Cluster prerequisite migration Plan pass 1 of 2 PASSED.\n'
    printf 'Expected summary: 14 to add, 0 to change, 0 to destroy.\n'
    printf 'This environment predates the Phase 4 Ignition Security Group attachment.\n'
    printf 'The new Security Group ID is not known until this migration pass is applied.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    printf 'Next: bash scripts/17-apply-cluster-prerequisites.sh\n'
    ;;
  attachment)
    printf 'Cluster prerequisite migration Plan pass 2 of 2 PASSED.\n'
    printf 'Expected summary: 0 to add, 1 to change, 0 to destroy.\n'
    printf 'The only managed change is the in-place Installer Security Group attachment.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    printf 'Next: bash scripts/17-apply-cluster-prerequisites.sh\n'
    ;;
  combined)
    printf 'Cluster prerequisite migration Plan validation PASSED.\n'
    printf 'Expected summary: 14 to add, 1 to change, 0 to destroy.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    printf 'Next: bash scripts/17-apply-cluster-prerequisites.sh\n'
    ;;
  converged)
    rm -- "$PLAN_FILE"
    printf 'Cluster prerequisites are already converged; no Apply is required.\n'
    printf 'Removed the no-op saved Plan.\n'
    printf 'Next: bash scripts/18-generate-stage-ignition.sh\n'
    ;;
esac
