# 14. 次の学習：オンプレミス UPI 模擬環境

## 14.1 この章の位置付け

ここまでの SNO 環境は、OpenShift のインストールと基本操作を短時間で体験するための入門環境です。

次の教材では、AWS の EC2 をオンプレミスの物理サーバーに見立て、汎用的なベアメタル UPI（User-Provisioned Infrastructure）構築を学びます。最初に本番環境に近いクラスターを完成させ、その環境を使って認証、ストレージ、監視、GitOps などを順番に学習します。

SNO のコードと手順は入門編として残し、UPI 模擬環境は別ディレクトリまたは別リポジトリに作成します。

## 14.2 学習目標

次の作業を、OpenShift Installer の自動作成に頼らず実施できることを目標とします。

1. サーバー、ネットワーク、IP アドレスを設計する
2. 正引き・逆引き DNS を構築する
3. API、Machine Config、Ingress 用ロードバランサーを構築する
4. Proxy と内部 Mirror Registry を構築する
5. `install-config.yaml` と Ignition ファイルを生成する
6. Bootstrap、Control Plane、Worker を正しい順序で起動する
7. Bootstrap の完了確認、切り離し、CSR 承認を行う
8. クラスターの初期運用設定を行う
9. 障害発生時に原因を切り分け、復旧する
10. restricted network から disconnected network へ移行する

## 14.3 完成させるアーキテクチャー

```text
利用者・管理者
      |
管理接続（VPN または管理用踏み台）
      |
+-----+--------------------------------------------------+
| 管理・基盤サービス                                    |
|                                                       |
|  Bastion / Installer                                  |
|  DNS-1 / DNS-2                                        |
|  Load Balancer-1 / Load Balancer-2                    |
|  Proxy                                                 |
|  Mirror Registry                                      |
|  NTP                                                   |
|  NFS                                                   |
+-----+--------------------------------------------------+
      |
+-----+--------------------------------------------------+
| OpenShift クラスター                                  |
|                                                       |
|  Bootstrap x 1（一時的。インストール後に削除）       |
|  Control Plane x 3                                    |
|  Worker x 3                                           |
+--------------------------------------------------------+
```

Control Plane と Worker は 3 つの Availability Zone に分散します。これは AWS の可用性を学ぶためだけでなく、オンプレミスにおけるラック、電源系統、障害ドメインの分離を考える練習にもなります。

## 14.4 AWS とオンプレミスの対応

| オンプレミスの要素 | AWS 学習環境での代替 | 学習上の注意 |
|---|---|---|
| 物理サーバーまたは仮想マシン | EC2 | EC2 の自動構築は Terraform で行う |
| サーバー用 VLAN | VPC と Private Subnet | Subnet は VLAN と完全に同じではない |
| 社内 DNS | EC2 上の BIND | Route 53 任せにせず、DNS レコードを自分で管理する |
| F5、A10、HAProxy など | EC2 上の HAProxy | API は Layer 4、セッション維持なしで構成する |
| Keepalived の仮想 IP | AWS NLB | AWS では L2 の仮想 IP を正確に再現できない |
| PXE または ISO 起動 | RHCOS AMI と Ignition | 実機編では PXE、ISO、BMC を別途学習する |
| SAN または NAS | EC2 上の NFS | 初期学習用。実本番のストレージ選定とは分ける |
| インターネット出口制御 | Proxy と NAT | 許可先と通信要件を記録する |
| 内部コンテナーレジストリ | Mirror Registry | disconnected 化の前にミラー手順を学ぶ |

この環境はオンプレミス UPI の作業を学ぶための模擬環境です。AWS 上の正式な本番 OpenShift 構成を目的とするものではありません。また、BMC、物理 NIC、VLAN、LACP、PXE、L2 仮想 IP、ストレージ装置などは AWS では完全に再現できません。

## 14.5 構築ツールと責任分界

### Terraform

次の AWS リソースを作成・削除します。

- VPC、Subnet、Route Table、Security Group
- EC2、固定 Private IP
- NLB
- 必要な EBS、IAM Role
- 構築期間だけ使用する接続経路

### Ansible

次の Linux サービスを構成します。

- BIND
- HAProxy
- Proxy
- Mirror Registry
- NTP
- NFS
- 構築前後の検査コマンド

### OpenShift Installer

次の OpenShift 用成果物を生成します。

- Kubernetes マニフェスト
- Bootstrap Ignition
- Control Plane Ignition
- Worker Ignition

UPI では、OpenShift Installer がサーバー、DNS、ロードバランサーを作成しません。利用者が準備した基盤へ RHCOS と Ignition を配置します。

## 14.6 ネットワーク条件

最初から完全 disconnected にせず、次の順番で進めます。

1. Private Subnet と制限付き外部接続を用意する
2. Proxy 経由で必要な接続先だけにアクセスする
3. OpenShift をインストールして正常性を確認する
4. リリースイメージと Operator Catalog を Mirror Registry に同期する
5. 外部通信を停止する
6. disconnected 状態でインストール、更新、Operator 導入を確認する

段階を分けることで、OpenShift の構築問題と disconnected 固有の問題を切り分けられるようにします。

## 14.7 最初に完成させる範囲

機能別学習へ進む前に、次をすべて完成させます。

- Control Plane 3 台と Worker 3 台が `Ready`
- ClusterOperator が正常
- Bootstrap サーバーを切り離し済み
- API と `api-int` の名前解決、負荷分散が正常
- `*.apps` の名前解決、負荷分散が正常
- 正引きと逆引き DNS が正常
- Web コンソールへ管理ネットワークから接続可能
- テストアプリケーションを Route 経由で利用可能
- NFS の StorageClass と PersistentVolume を利用可能
- ノード再起動後もクラスターが正常復帰
- Terraform と Ansible で環境を再作成可能
- 削除手順と残存リソース確認が正常

## 14.8 完成後の機能別学習

完成した HA クラスターを使い、次の順番で学習します。

1. Project、Namespace、ResourceQuota、LimitRange
2. Deployment、Service、Route、ConfigMap、Secret
3. Probe、PodDisruptionBudget、スケジューリング
4. Identity Provider、User、Group、RBAC
5. SCC、ServiceAccount、NetworkPolicy
6. PersistentVolume、StorageClass、バックアップ・リストア
7. OperatorHub と Operator Lifecycle Manager
8. Monitoring、Alerting、Logging
9. Image Registry とイメージ管理
10. OpenShift Pipelines と GitOps
11. MachineConfig、Node の保守、証明書管理
12. バージョン更新と Operator 更新
13. Control Plane、Worker、DNS、LB、ストレージの障害試験
14. restricted / disconnected 運用

MachineConfig などの OpenShift 正規管理方法を使用し、Node へ SSH して恒久設定を直接変更する運用は避けます。

## 14.9 初心者向け教材の書き方

UPI 模擬編では、各手順に次を記載します。

- 何を作る操作なのか
- なぜ必要なのか
- コマンドをどのサーバーで実行するのか
- 実行前の前提条件
- 正常時の出力例
- 確認コマンド
- 失敗した場合の切り分け方法
- AWS 固有部分と実オンプレミス部分の違い
- 作成される課金対象と削除方法

値をコピーするだけの手順にせず、DNS、ロードバランサー、Ignition、Bootstrap、CSR がどのようにつながるかを説明します。

## 14.10 構築フェーズ

| フェーズ | 内容 | 完了条件 |
|---|---|---|
| 1 | 要件、サーバー、IP、DNS、ポート設計 | パラメーターシート完成 |
| 2 | Terraform で AWS 模擬基盤を作成 | EC2 とネットワークへ接続可能 |
| 3 | Ansible で基盤サービスを構成 | DNS、LB、Proxy、Registry、NTP、NFS の検査成功 |
| 4 | UPI 用ファイルを生成 | Manifest と Ignition の検査成功 |
| 5 | Bootstrap と Control Plane を起動 | Bootstrap Complete |
| 6 | Worker を追加 | 全 Node が Ready |
| 7 | 初期運用設定 | Console、Ingress、Storage、認証が正常 |
| 8 | 機能別演習 | 各演習のテスト成功 |
| 9 | 障害・復旧演習 | 想定障害から復旧可能 |
| 10 | disconnected 化 | 外部接続なしで指定操作が可能 |
| 11 | 環境削除 | 課金対象の残存なし |

本番相当の 3 AZ 環境は学習期間中だけ使用し、演習後は直ちに削除します。再学習時に同じ環境を再現できることも、Terraform と Ansible を使用する目的の一つです。

## 14.11 次に作成する教材

次の作業では、SNO 編とは別に以下を作成します。

1. UPI 模擬環境の全体構成図
2. AWS と実オンプレミスの差分表
3. サーバー、IP アドレス、DNS レコード、ポートのパラメーターシート
4. Terraform による AWS 模擬基盤
5. Ansible による基盤サービス構築
6. OpenShift UPI インストール手順
7. 構築前検査、構築後検査、削除後検査
8. 機能別・障害別の演習手順

参考資料：

- [Red Hat OpenShift Container Platform 4.21: Installing on bare metal](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_bare_metal/index)
- [Red Hat OpenShift Container Platform 4.21: Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_an_on-premise_cluster_with_the_agent-based_installer/index)
