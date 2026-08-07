# 08. 構築後の確認と Console

```bash
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
bash scripts/06-check-cluster.sh
oc whoami --show-console
```

Node=Ready、ClusterVersion=Available、安定後の全 Operator が Available=True / Progressing=False / Degraded=False なら正常です。直後は一時的 Progressing もあるため events/log と時間経過を確認します。

初期 `kubeadmin` password は `$INSTALL_DIR/auth/kubeadmin-password` にあります。コマンドで読む場合も画面共有・履歴・README へ出さず、学習後は Identity Provider と通常管理者を設定して kubeadmin を恒久利用しません。Console 不通時は `dig`、Route 53、証明書時刻、Ingress Pod/Operator、LB target/SG を順に確認します。

次: [サンプル](09-deploy-sample-app.md)

