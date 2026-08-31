# 09. サンプルアプリ

別のターミナルから章単独で再開しても正しいkubeconfigを使うよう、設定を明示的に読み込みます。

```bash
(
  set -Eeuo pipefail
  source configs/environment
  export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
  [[ -r "$KUBECONFIG" ]] || {
    echo "ERROR: kubeconfig is not readable: $KUBECONFIG" >&2
    exit 1
  }

  bash scripts/07-deploy-sample-app.sh
  oc -n sample-app get deploy,pod,svc,route
  oc -n sample-app logs deployment/hello-openshift
)
```

DeploymentがPodを管理し、Serviceが安定した内部宛先、OpenShift固有のRouteがrouter経由の外部URLを提供します。Ingressと目的は似ますが、RouteはOpenShift APIです。公開・認証不要のサンプルイメージは、Quayで存在を確認した `4.16.0` のmanifest digestで固定しています。サンプルイメージの版はOCPクラスターバージョンとは独立しています。

サンプルだけを削除する場合も、正しいkubeconfigを同じサブシェルで設定します。

```bash
(
  set -Eeuo pipefail
  source configs/environment
  export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
  [[ -r "$KUBECONFIG" ]]
  oc delete namespace sample-app
)
```

次: [コスト](10-cost-management.md)
