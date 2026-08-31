#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
PLAN_FILE="$TERRAFORM_DIR/cluster-prerequisites.tfplan"

for command_name in aws jq terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context

[[ -s "$PLAN_FILE" ]] || {
  printf 'ERROR: Missing saved prerequisite plan: %s\n' "$PLAN_FILE" >&2
  exit 1
}

changes_json="$(phase6_managed_plan_changes_json "$PLAN_FILE")"
plan_kind="$(phase6_prerequisite_plan_kind "$changes_json")" \
  || phase6_error 'Saved Plan does not exactly match an allowed OpenShift prerequisite pass. Do not apply.'
[[ "$plan_kind" != converged ]] || phase6_error 'Saved Plan has no managed changes. Run scripts/06-02-plan-cluster-prerequisites.sh again.'
phase6_assert_plan_account "$PLAN_FILE"

printf 'Validated saved prerequisite Plan kind: %s\n' "$plan_kind"

read -r -p 'Type APPLY-CLUSTER-PREREQUISITES to continue: ' CONFIRM
if [[ "$CONFIRM" != 'APPLY-CLUSTER-PREREQUISITES' ]]; then
  printf 'Apply cancelled.\n'
  exit 0
fi

terraform -chdir="$TERRAFORM_DIR" apply "$PLAN_FILE"
rm -- "$PLAN_FILE"
printf 'Applied the saved prerequisite Plan and removed the consumed Plan file.\n'

case "$plan_kind" in
  resources)
    printf 'The prerequisite resources now exist. A second Plan is required to attach the new Security Group to Installer.\n'
    printf 'Next: bash scripts/06-02-plan-cluster-prerequisites.sh\n'
    ;;
  prerequisites | attachment | combined)
    printf 'Cluster prerequisite application is complete.\n'
    printf 'Next: bash scripts/06-04-generate-stage-ignition.sh\n'
    ;;
esac
