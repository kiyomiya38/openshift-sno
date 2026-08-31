# 07. インストール

```bash
bash scripts/05-create-cluster.sh
```

スクリプトは `configs/environment` を自動的に読み込み、内部で次の処理を実行してログへ保存します。次のコードは処理内容の説明用であり、利用者がスクリプトとは別に実行しません。

```bash
openshift-install create cluster --dir "$INSTALL_DIR" --log-level=debug
```

bootstrap完了、API/control plane起動、ClusterOperator安定化を待ちます。同じinstall directoryで `create cluster` を再実行しません。debug logには秘密が含まれ得るので共有前に精査します。失敗時はログを保全し、[トラブルシューティング](12-troubleshooting.md)を参照します。

次: [構築後確認](08-post-install-check.md)
