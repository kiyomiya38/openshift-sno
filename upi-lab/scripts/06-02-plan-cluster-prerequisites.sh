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
  || phase6_error 'Plan does not exactly match an allowed OpenShift prerequisite pass. Do not apply.'

print_review_guidance() {
  printf 'Next: review the saved Plan before Apply:\n'
  printf '  terraform -chdir=%q show -no-color %q\n' "$TERRAFORM_DIR" "$PLAN_FILE"
  printf 'After the review passes: bash scripts/06-03-apply-cluster-prerequisites.sh\n'
}

case "$plan_kind" in
  prerequisites)
    printf 'Cluster prerequisite Plan validation PASSED.\n'
    printf 'Expected summary for a clean build: 13 to add, 0 to change, 0 to destroy.\n'
    printf 'The Installer-only Ignition Security Group was already attached during the infrastructure construction stage.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    print_review_guidance
    ;;
  resources)
    printf 'Cluster prerequisite migration Plan pass 1 of 2 PASSED.\n'
    printf 'Expected summary: 14 to add, 0 to change, 0 to destroy.\n'
    printf 'This environment predates the infrastructure-stage Ignition Security Group attachment.\n'
    printf 'The new Security Group ID is not known until this migration pass is applied.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    print_review_guidance
    ;;
  attachment)
    printf 'Cluster prerequisite migration Plan pass 2 of 2 PASSED.\n'
    printf 'Expected summary: 0 to add, 1 to change, 0 to destroy.\n'
    printf 'The only managed change is the in-place Installer Security Group attachment.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    print_review_guidance
    ;;
  combined)
    printf 'Cluster prerequisite migration Plan validation PASSED.\n'
    printf 'Expected summary: 14 to add, 1 to change, 0 to destroy.\n'
    printf 'Saved plan: %s\n' "$PLAN_FILE"
    print_review_guidance
    ;;
  converged)
    rm -- "$PLAN_FILE"
    printf 'Cluster prerequisites are already converged; no Apply is required.\n'
    printf 'Removed the no-op saved Plan.\n'
    printf 'Next: bash scripts/06-04-generate-stage-ignition.sh\n'
    ;;
esac
