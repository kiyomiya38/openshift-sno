# 07. インストール

```bash
bash scripts/05-create-cluster.sh
```

内部では次をログへ保存します。

```bash
openshift-install create cluster --dir "$INSTALL_DIR" --log-level=debug
```

bootstrap 完了、API/control plane 起動、ClusterOperator 安定化を待ちます。同じ install directory で `create cluster` を再実行しません。debug log には秘密が含まれ得るので共有前に精査します。失敗時はログを保全し、[トラブルシューティング](12-troubleshooting.md) を参照します。

次: [構築後確認](08-post-install-check.md)

