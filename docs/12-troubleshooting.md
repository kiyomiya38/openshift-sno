# 12. トラブルシューティング

まず `grep -iE 'error|failed|timeout' logs/*.log`、AWS CloudTrail、`oc get events -A --sort-by=.lastTimestamp` を読みます。秘密を伏せてから共有します。

| 症状 | 考えられる原因 | 確認 / 正常例 | 異常例・修正 | 再発防止 |
|---|---|---|---|---|
| AWS 認証エラー | profile/期限/時刻 | `aws sts get-caller-identity` が JSON | ExpiredToken→SSO 再 login | 短期 credential と時刻同期 |
| Access Keyを画面・チャットへ掲載 | credential漏えい | 該当キーを即時Inactive | 投稿削除だけで継続使用→危険 | キーをローテーションしCloudTrail確認 |
| AccessDenied | IAM action 不足 | installer preflight 通過 | denied action を公式 policy と照合 | 対象 minor の権限表を採用 |
| Hosted Zone 不明 | 別 account/名前末尾 | zone ID が 1 件 | `None`→profile/base domain 修正 | 事前スクリプト |
| DNS 不通 | 委任/伝播/base domain ミス | `dig NS` と zone NS 一致 | NXDOMAIN→registrar 委任修正 | 構築前に外部 resolver で確認 |
| 構築開始直後にAPI名が`no such host` | IPIがAPI DNS/LBをまだ作成中 | 数分後に`dig +short api.<cluster>.<baseDomain>`が返り、`curl -k https://api.<cluster>.<baseDomain>:6443/version`が応答 | DNSが作られないまま長時間停止→Route 53、LB、installer logを確認 | 直後の一時エラーで中断・再実行・手動レコード作成をしない |
| instance type 不可 | 大阪で未提供 | offering に候補が出る | 空→別の 8 vCPU/必要 RAM 型 | 毎回 API 照会 |
| vCPU/EIP/VPC quota | quota 不足 | Service Quotas に余裕 | limit exceeded→増枠/不要資源整理 | 数日前に申請 |
| Pull Secret error | JSON/改行/期限 | `jq -e` 成功 | parse/image pull error→再取得 | 秘密ファイルから注入 |
| SSH key error | 秘密鍵/形式違い | `.pub` が `ssh-ed25519` 等 | invalid key→公開鍵を指定 | 事前 grep |
| YAML error | indent/未知 field | `openshift-install explain` | unmarshal→対象版 schema に修正 | 静的 test |
| bootstrap で停止 | network/DNS/IAM/quota | bootstrap complete | timeout→installer log と AWS events | preflight と変更凍結 |
| API 不通 | LB target/SG/DNS/node | `oc whoami` 成功 | timeout/TLS→DNS、LB、SG、時刻 | IPI 資源を手編集しない |
| Console 不通 | ingress/DNS/cert | console URL が HTTPS 応答 | NXDOMAIN/503→Ingress Operator/Route | wildcard DNS 確認 |
| Operator Degraded | 下位 Pod/依存 API | True/False/False | message を `oc describe co` | 安定化まで変更しない |
| Node NotReady | kubelet/network/storage | Ready=True | conditions/journal を確認 | node へ手動変更しない |
| ImagePullBackOff | image/tag/network/auth | Pod Running | events が manifest/DNS/NAT を示す | version tag と到達性検査 |
| NAT 経由で通信不能 | route/NAT/EIP/SG | node image pull 成功 | timeout→route/NAT state を確認 | IPI topology を維持 |
| destroy 失敗 | credential/依存/metadata | installer complete | log の ARN/tag を追跡 | install dir と metadata 保全 |
| 資源・課金が残る | 手動 EC2 削除/削除失敗 | leftover が空 | Cost Explorer/tag で特定 | 必ず installer destroy |
| kubeconfig/password 紛失 | install dir 削除 | auth が読める | API accessなし→既存 IdP/管理者を使用 | 暗号化 backup/IdP 設定 |

未知の問題は対象版の [installation validation and troubleshooting](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/) と Red Hat support data collection を使い、ノードへの直接 SSH 修正は最後の診断手段に限定します。
