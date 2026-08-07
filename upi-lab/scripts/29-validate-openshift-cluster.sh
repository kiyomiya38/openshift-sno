#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/phase6-common.sh
source "$SCRIPT_DIR/lib/phase6-common.sh"
# shellcheck source=lib/phase7-common.sh
source "$SCRIPT_DIR/lib/phase7-common.sh"

for command_name in aws curl jq oc terraform; do
  phase6_require_command "$command_name"
done
phase6_assert_execution_context
phase6_require_file "$INSTALL_DIR/install-complete.ok"
phase7_assert_target_cluster "$INSTALL_DIR/auth/kubeconfig"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

nodes_json="$(oc get nodes -o json)"
node_count="$(jq -r '.items | length' <<<"$nodes_json")"
ready_count="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
[[ "$node_count" == 6 ]] && pass 'Six permanent nodes are registered.' || fail "Expected six nodes, found $node_count."
[[ "$ready_count" == 6 ]] && pass 'All six nodes are Ready.' || fail "Only $ready_count of six nodes are Ready."

cluster_available="$(oc get clusterversion version -o json | jq -r 'any(.status.conditions[]; .type == "Available" and .status == "True")')"
[[ "$cluster_available" == true ]] && pass 'ClusterVersion is Available.' || fail 'ClusterVersion is not Available.'

bad_operators="$(oc get clusteroperators -o json | jq -r '[.items[] | select(
  (any(.status.conditions[]; .type == "Available" and .status == "True") | not) or
  any(.status.conditions[]; .type == "Progressing" and .status == "True") or
  any(.status.conditions[]; .type == "Degraded" and .status == "True")
)] | length')"
[[ "$bad_operators" == 0 ]] && pass 'All ClusterOperators are stable.' || fail "$bad_operators ClusterOperators are not stable."

pending_csrs="$(oc get csr -o json | jq -r '[.items[] | select((.status.conditions // []) | length == 0)] | length')"
[[ "$pending_csrs" == 0 ]] && pass 'No pending CSR remains.' || fail "$pending_csrs pending CSRs remain."

curl --fail --silent --show-error --insecure https://api.ocp.lab.k8study.com:6443/readyz >/dev/null \
  && pass 'External API DNS and NLB path is ready.' || fail 'API readyz failed through the NLB.'

console_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
curl --fail --silent --show-error --insecure --head "https://$console_host" >/dev/null \
  && pass "Console route is reachable: $console_host" || fail "Console route is not reachable: $console_host"

target_groups_json="$(terraform -chdir="$TERRAFORM_DIR" output -json internal_nlb_target_groups)"
while IFS=$'\t' read -r service target_group_arn; do
  health_json="$(aws elbv2 describe-target-health \
    --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" \
    --target-group-arn "$target_group_arn" --output json)"
  healthy_count="$(jq -r '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length' <<<"$health_json")"
  total_count="$(jq -r '.TargetHealthDescriptions | length' <<<"$health_json")"
  [[ "$total_count" == 2 && "$healthy_count" == 2 ]] \
    && pass "NLB target group $service has two healthy HAProxy targets." \
    || fail "NLB target group $service has $healthy_count/$total_count healthy targets."
done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"$target_groups_json")

terraform_state_list="$(terraform -chdir="$TERRAFORM_DIR" state list)"
terraform_nodes="$(grep -c '^aws_instance\.openshift\[' <<<"$terraform_state_list" || true)"
bootstrap_nodes="$(grep -c 'aws_instance\.openshift\["bootstrap"\]' <<<"$terraform_state_list" || true)"
[[ "$terraform_nodes" == 6 && "$bootstrap_nodes" == 0 ]] \
  && pass 'Terraform manages six permanent nodes and no Bootstrap node.' \
  || fail "Terraform node state is unexpected: total=$terraform_nodes bootstrap=$bootstrap_nodes."

printf '\n=== Result ===\nFailures: %d\n' "$failures"
(( failures == 0 )) || exit 1
printf 'OpenShift cluster validation PASSED.\n'
