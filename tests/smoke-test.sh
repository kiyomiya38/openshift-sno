#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib.sh"; load_env; need oc; need curl
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
oc whoami >/dev/null
oc wait node --all --for=condition=Ready --timeout=5m
oc wait clusterversion/version --for=condition=Available --timeout=10m
bad="$(oc get co --no-headers | awk '$3!="True" || $4!="False" || $5!="False"')"; [[ -z "$bad" ]] || { echo "$bad" >&2; exit 1; }
console="$(oc whoami --show-console)"; host="$(oc -n sample-app get route hello-openshift -o jsonpath='{.spec.host}')"
dig +short "${host}" | grep -q .
curl -fsS --retry 5 "http://${host}" >/dev/null
printf 'PASS: API, Node, ClusterVersion, Operators, DNS, Console (%s), sample Route\n' "$console"
