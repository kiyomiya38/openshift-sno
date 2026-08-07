# 検証レポート

この文書は再利用可能な構築手順から実行実績を分離するための記録です。ここに記載する結果は、読者の環境が現在同じ状態であることを示しません。AWS Account ID、ARN、Cluster ID、Instance ID、証明書、state、Plan、kubeconfigなどの環境固有値は掲載しません。

## 検証対象

| 項目 | 内容 |
|---|---|
| 検証日 | 2026-08-07 |
| OpenShift | 4.21.26、x86_64 |
| AWSリージョン | `ap-northeast-3` |
| 構成 | `platform: none`、Control Plane 3台、Worker 3台 |
| 管理端末 | Windows 11、WSL2、Ubuntu 24.04系 |

> [!IMPORTANT]
> この実績はdistribution hardening前のrevisionに対するものです。その後、Client VPN 2 AZ化、依存関係/AMI固定、部分state destroy、local cleanup、release auditを変更しています。変更後の配布候補は、クリーンな環境で同じE2Eシナリオを再実行し、この注記を更新するまで「静的検査済み・E2E再検証待ち」です。

## 完了したシナリオ

- 事前検査からTerraformネットワーク、Client VPN、基盤EC2、Ansibleサービスまでの新規構築
- Client VPN DNSのVPC ResolverからBIND 2台への切り替え
- Manifest/Ignition生成、Bootstrap、CSR個別承認、`install-complete`
- Bootstrap EC2とIgnition HTTP配信資材の削除
- 6 Node Ready、ClusterVersion、全ClusterOperator、API、Console、NLB Target Groupの完成検査
- NFS Subdir External Provisioner、非default `nfs-rwx` StorageClass、Pod再作成を伴うRWX永続性試験
- `haproxy-0`、`haproxy-1`の片系停止と完全復旧
- `worker-0`、`worker-2`、`worker-1`の計画再起動と完全復旧
- Terraform destroy、Client VPN用ACM証明書削除、残存AWSリソース検査

代表的な合格メッセージは次のとおりです。

```text
Preflight PASSED. It is safe to continue to Terraform planning.
Network validation PASSED.
Client VPN validation PASSED.
Infrastructure services validation PASSED.
Cluster prerequisite validation PASSED.
Bootstrap completion PASSED.
OpenShift cluster validation PASSED.
NFS StorageClass persistence validation PASSED.
HAProxy single-side failure test PASSED.
Worker planned reboot test PASSED.
Cleanup validation PASSED. No lab resources were found.
```

## 検証対象外

- disconnected/mirroring完了後の外部通信遮断
- Control Planeの計画再起動、etcdバックアップ/リストア
- Client VPN target associationの複数AZ化
- NFS、Registry、NAT Gatewayの冗長化
- アップグレード、証明書更新、長期連続稼働、負荷・性能試験
- AWS IPIやRed Hatの正式なAWSサポート構成との同等性

## 再現性の制約

AMI、Terraform provider、Ansible Collection、コンテナーイメージは配布版で固定しています。一方、RHEL基盤ホストへ`dnf`で導入するRPMは、実行時に設定済みrepositoryが提供するversionへ解決されます。そのため、別日に構築したサービスホストのbyte-for-byte同一性は保証しません。repository metadataと導入済みRPM versionを検証記録へ残し、配布候補ごとにクリーンなE2Eを再実行します。

## リリース時の更新方法

配布する各リリースでは、クリーンなAWS環境から構築・検証・削除を再実施し、日付、正確なツール・RPM version、合格したシナリオ、既知の未検証項目を更新します。実行ログそのものは機微情報を含むため公開配布物へ同梱しません。
