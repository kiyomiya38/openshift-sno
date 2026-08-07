# 00. 全体像

## この章の目的
IPI と SNO の境界を理解します。

## 完了時の状態
AWS 上に public SNO が 1 台あり、API、Console、Route に DNS 経由で接続できます。

## 構成の説明
`openshift-install` は手元の Linux で実行され、AWS API を通じて一時 bootstrap 資源と恒久資源を作ります。RHCOS はインストーラー管理です。SNO では worker replica 0、control-plane replica 1 により master が workload も実行します。

## 実行手順
README の章順に進みます。IPI が作る資源を個別に手作業で先行作成しません。

## 確認方法
構築後は Node Ready、ClusterVersion Available、全 ClusterOperator の Available=True / Progressing=False / Degraded=False を安定条件とします。

## チェックポイント
- 対象は AWS IPI。ROSA、CRC、Assisted Installer、bare-metal Agent-based、既存 VPC/UPI は含めない。
- SNO は HA ではない。

## 次の章へ進む条件
[アーキテクチャ](01-architecture.md) の責任分界を説明できること。

