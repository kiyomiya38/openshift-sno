# 01. アーキテクチャ

## この章の目的
AWS 資源と OpenShift 機能の対応を理解します。

## Archifyアーキテクチャ図

### SNO / UPI 比較

![AWS IPIのSingle Node OpenShiftと、platform noneで構成するUPI模擬ラボの比較図。](../diagrams/archify/00-sno-upi-comparison.svg)

[操作可能なHTML（GitHub Pages）](https://kiyomiya38.github.io/openshift-sno/00-sno-upi-comparison.html) / [PNG](../diagrams/archify/00-sno-upi-comparison.png) / [SVG](../diagrams/archify/00-sno-upi-comparison.svg)

### SNO（AWS IPI）詳細

![利用者と管理端末から、Route 53、External Load Balancer、SNOノード、EBS、NAT Gatewayへ至るAWS IPI詳細図。](../diagrams/archify/01-sno-ipi-detail.svg)

[操作可能なHTML（GitHub Pages）](https://kiyomiya38.github.io/openshift-sno/01-sno-ipi-detail.html) / [PNG](../diagrams/archify/01-sno-ipi-detail.png) / [SVG](../diagrams/archify/01-sno-ipi-detail.svg)

UPI側の詳細は[UPI構成とパラメーター](../upi-lab/docs/01-architecture-and-parameters.md#archify詳細図)を参照してください。

## 構成の説明

| AWS 資源 | OpenShift での役割 | 必要性・課金 | 削除時の注意 |
|---|---|---|---|
| VPC/Subnet/Route Table/IGW | ノード・LB のネットワーク | 分離と経路。多くは本体無料 | 依存 ENI/LB/NAT を先に処理 |
| NAT Gateway/EIP | private subnet から外部取得 | pull、更新、AWS API。時間/通信課金 | EC2 停止中も課金し得る |
| EC2/EBS | SNO ノード/RHCOS 永続ディスク | control plane と workload | EC2 だけ手動削除しない |
| NLB/ALB・Target Group | API/Ingress の入口 | 外部公開。時間/LCU 等 | target/ENI の依存を確認 |
| Route 53 record | `api` と `*.apps` の名前解決 | クライアント到達 | Hosted Zone 自体は原則残す |
| IAM Role/Profile | ノードとインストーラーの AWS 操作 | cloud integration | 他用途 role を消さない |
| S3 | bootstrap/install artifact の一時保管等 | 対象版が必要時のみ作成 | 実資源をタグ/metadata で確認 |
| Security Group | API、Ingress、node 通信の制御 | 到達性と最小権限 | ENI 依存を先に解消 |
| Public IPv4 | public endpoint/instance | AWS の時間課金対象になり得る | 未関連 IP を解放しない |

対象バージョンで全項目が必ず個別作成されるとは限りません。`metadata.json` の infraID とクラスタタグで実物を確認します。

## 確認方法
構築後に `bash scripts/08-collect-aws-resources.sh` を実行します。

## よくあるエラー
資源名だけで検索すると同名・別用途を誤認します。タグを主キーにし、削除はインストーラーへ任せます。

## 次の章へ進む条件
[前提条件](02-prerequisites.md) を準備できること。
