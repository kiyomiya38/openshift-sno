# リリースノート

この文書は配布版の仕様変更を記録します。個別環境のCluster ID、Instance ID、Account ID、実行状態は[検証レポート](validation-report.md)にも掲載しません。

## 2026-08 配布準備版

初回の第三者配布に向け、次を改善しました。

### 文書と配布境界

- 全体アーキテクチャ、AZ・Subnet配置、主要通信フローのMermaid原本とSVG/PNGを追加。
- 図の固定版レンダリング手順と、Mermaid/SVG/PNGの静的検証を追加。
- リポジトリ直下をSNOラボとUPI模擬ラボの選択ページへ変更。
- 再利用手順から実行日、現行Cluster ID、Instance ID、完了状態を分離。
- 個人のWindows/WSLパスを`LAB_ROOT`と利用者プレースホルダーへ変更。
- 固定プロファイル、サポート境界、単一障害点、料金、時間、必要IAM権限を明記。
- disconnected/mirror同期が未実装であり、Proxyはネットワークで強制されないことを明記。
- 構築実績、移行履歴、配布版変更履歴をそれぞれ別文書へ分離。

### 再現性と安全性

- 承認済みAWS Account IDを現在のloginとは別経路で指定する方針へ変更。
- RHEL 9.6 AMIをリリース単位の検証済みIDへ固定。
- Terraform provider、Ansible Collection、コンテナーイメージなどの依存関係を固定する方針を追加。
- RHELの`dnf` packageは実行時repositoryへ解決されるためbyte-for-byte再現を保証せず、配布候補ごとのE2E再検証を必須化。
- Client VPNを`infra-a`/`infra-b`の2 AZ target associationへ変更。
- 初期Plan、保存Plan、workspace、state identity、部分構築からのdestroy guardを強化。
- HAProxy/Worker recovery markerがある状態でのdestroyを禁止。

### 完全削除

- destroy Plan作成後、Apply前にWindows Client VPNを切断する順序を明記。
- NFS、Registry、etcdのデータ消失と退避確認を追加。
- ACM削除の確認文字列`DELETE-LAB-CERTIFICATE`を明記。
- AWS残存検査が合格するまでlocal stateを削除しないルールを追加。
- クラスター固有資材、Terraform生成物、ログ、VPN profile、PKI、AWS credentialを分類。
- ローカルcleanupと配布物auditを、AWS destroyとは別の安全な工程として追加。
- release builderの再現性と禁止ファイル拒否を一時fixtureで検査するself-testを追加。

### リリース判定

この版は、静的検査だけで配布完了とはしません。変更後のクリーンなAWSアカウント/作業端末で、構築、NFS、HAProxy、Worker、完全削除を再実施し、[検証レポート](validation-report.md)を更新してから正式配布します。
