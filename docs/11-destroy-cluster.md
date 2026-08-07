# 11. クラスターを安全に削除する

対象名、region、account、install directory、`metadata.json`、必要データの退避、実行中 workload を確認します。infraID を控えます。

```bash
export INFRA_ID="$(jq -r .infraID "$INSTALL_DIR/metadata.json")"
bash scripts/09-destroy-cluster.sh
bash scripts/10-check-leftover-resources.sh
```

削除スクリプトは account をマスク表示し、クラスター名の完全一致入力を要求します。`yes` だけでは消しません。installer の基本コマンドは `openshift-install destroy cluster --dir "$INSTALL_DIR" --log-level=info` です。

残存確認対象は NAT Gateway、LB、EBS、EIP、Route 53 record、S3、SG、ENI 等です。自動削除失敗時は依存関係（LB/ENI→SG/VPC、NAT→EIP/subnet 等）を調べ、infraID/tag が一致する物だけを処理します。アカウント内の無関係資源を名前だけで削除しません。

