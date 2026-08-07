# 配布版の移行ノート

新規利用者はこの文書を使用しません。配布版を更新するときは、最も安全な方法として旧環境を完全削除し、クリーンなstateから再構築することを推奨します。

## Installer用Ignition Security Group導入前のstate

Installer用Ignition Security GroupをPhase 4で作成・装着する前の定義からstateを継続した場合、スクリプト16/17は次の2段階Planを要求することがあります。

1回目:

```text
Plan: 14 to add, 0 to change, 0 to destroy.
Cluster prerequisite migration Plan pass 1 of 2 PASSED.
```

1回目のApply後、Security Group IDが確定した状態でもう一度`scripts/16-plan-cluster-prerequisites.sh`を実行します。

2回目:

```text
Plan: 0 to add, 1 to change, 0 to destroy.
aws_instance.infrastructure["installer"]    update
Cluster prerequisite migration Plan pass 2 of 2 PASSED.
```

2回目はInstaller EC2を置換せず、Ignition Server用Security Groupを追加するin-place更新です。`delete`、`replace`、他リソースの`update`が含まれる場合はApplyしません。各Planは保存後に内容を確認し、同じスクリプト17と確認文字列`APPLY-CLUSTER-PREREQUISITES`で個別にApplyします。

移行完了後、[07. OpenShift UPIインストール](07-openshift-install.md#4-manifestとignitionを生成配信する)へ戻ります。
