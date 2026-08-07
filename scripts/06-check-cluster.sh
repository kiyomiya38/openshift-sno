#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need oc
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"; [[ -r "$KUBECONFIG" ]] || die "kubeconfig がありません"
oc whoami
oc get nodes -o wide
oc get clusterversion
oc get clusteroperators
bad="$(oc get clusteroperators --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')"
[[ -z "$bad" ]] || { printf '安定条件外の ClusterOperator（直後の Progressing は一時的な場合があります）:\n%s\n' "$bad"; exit 1; }
oc get pods -A
oc get infrastructure cluster -o yaml
oc get ingresscontroller default -n openshift-ingress-operator
oc get route -A
