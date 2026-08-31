# 配布版の移行ノート

新規利用者はこの文書を使用しません。配布版を更新するときは、最も安全な方法として旧環境を完全削除し、クリーンなstateから再構築することを推奨します。

## 文書・スクリプト改番前からの継続

番号付き文書は00～08、実行スクリプトは`章番号-章内連番-処理名`へ統一しました。旧`03-build-runbook.md`と旧00～35形式のスクリプト名は使用しません。完了済み工程に対応する新しい章を開き、その章の検証から現在状態を確認します。

Terraformのstate名と保存Plan名は改番していません。改番前に作成した保存Planでも、作成後にstate、workspace、AWS Account/region、Terraform resource定義が変わっておらず、新しいApplyスクリプトのguardと人手レビューに合格する場合は対応する新しいApplyスクリプトで継続できます。どれかを確認できない場合は保存PlanをApplyせず、同じ章のplannerから作り直します。

## Installer用Ignition Security Group導入前のstate

Installer用Ignition Security Groupを05章で作成・装着する前の定義からstateを継続した場合、`scripts/06-02-plan-cluster-prerequisites.sh`と`scripts/06-03-apply-cluster-prerequisites.sh`は次の2段階Planを要求することがあります。

1回目:

```text
Plan: 14 to add, 0 to change, 0 to destroy.
Cluster prerequisite migration Plan pass 1 of 2 PASSED.
```

1回目のApply後、Security Group IDが確定した状態でもう一度`scripts/06-02-plan-cluster-prerequisites.sh`を実行します。

2回目:

```text
Plan: 0 to add, 1 to change, 0 to destroy.
aws_instance.infrastructure["installer"]    update
Cluster prerequisite migration Plan pass 2 of 2 PASSED.
```

2回目はInstaller EC2を置換せず、Ignition Server用Security Groupを追加するin-place更新です。`delete`、`replace`、他リソースの`update`が含まれる場合はApplyしません。各Planは保存後に内容を確認し、同じ`scripts/06-03-apply-cluster-prerequisites.sh`と確認文字列`APPLY-CLUSTER-PREREQUISITES`で個別にApplyします。

移行完了後、[06. OpenShift UPIインストール](06-openshift-install.md#4-manifestとignitionを生成配信する)へ戻ります。
