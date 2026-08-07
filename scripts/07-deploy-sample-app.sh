#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}" >&2' ERR
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"; load_env; need oc; need curl
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
oc get namespace sample-app >/dev/null 2>&1 || oc create namespace sample-app
oc apply -f "$ROOT_DIR/manifests"
oc -n sample-app rollout status deployment/hello-openshift --timeout=5m
host="$(oc -n sample-app get route hello-openshift -o jsonpath='{.spec.host}')"
curl --fail --retry 10 --retry-delay 3 "http://${host}"
info "Route: http://${host}"
