# 03. 構築作業の全体フロー

## この章の目的

この章を構築作業の入口とし、個別章を番号順に進めます。状態欄は実行者の作業記録へコピーして使用し、この配布文書自体へ「完了」や環境固有IDを書き込みません。プロジェクトの過去の実機検証は[検証レポート](validation-report.md)を参照してください。

最初に、現在のcloneに対する絶対パスを設定します。新しいWSLシェルを開いた場合は毎回設定し直します。

```bash
cd /path/to/openshift-sno/upi-lab
export LAB_ROOT="$PWD"
test -x "$LAB_ROOT/scripts/00-preflight.sh"
```

## フェーズ一覧

| Phase | 作業 | 主な手順 | 完了の証拠 |
|---|---|---|---|
| 0 | 事前準備と構築前検査 | [02. 事前準備](02-prerequisites.md) | `Preflight PASSED` |
| 1 | ネットワークPlan | [04. ネットワーク](04-terraform-network.md) | Planが追加のみ |
| 2 | ネットワークApplyと検証 | [04. ネットワーク](04-terraform-network.md) | `Network validation PASSED` |
| 3 | Client VPN | [05. Client VPN](05-client-vpn.md) | `Client VPN validation PASSED`、Windows接続 |
| 4 | 基盤EC2、NLB、Security Group | [06. 基盤サービス](06-infrastructure-services.md) | `Infrastructure validation PASSED` |
| 5 | DNS、NTP、HAProxy、Proxy、Registry、NFS | [06. 基盤サービス](06-infrastructure-services.md) | `Infrastructure services validation PASSED` |
| 5.5 | Client VPN DNSをBINDへ切り替え | [05. Client VPN](05-client-vpn.md#dnsの段階的な切り替え) | AWS/Windows DNS検証合格 |
| 6 | Manifest、Ignition、OpenShift | [07. インストール](07-openshift-install.md) | `OpenShift cluster validation PASSED` |
| 7 | StorageClassと障害試験 | [08. 検証](08-validation-and-destroy.md) | 選択した試験が合格し完全復旧 |
| 8 | disconnected化 | 対象外 | この配布版では実施しない |
| 9 | AWS/ローカル完全削除 | [08. 完全削除](08-validation-and-destroy.md#6-完全削除) | AWS検査合格後、スクリプト35でlocal cleanup |

## Phase 0: 事前準備と構築前検査

```bash
cd "$LAB_ROOT"
bash scripts/00-preflight.sh
```

このスクリプトはAWSへ変更を加えません。次を確認してからPhase 1へ進みます。

```text
Failures: 0
Warnings: 0
Preflight PASSED. It is safe to continue to Terraform planning.
```

AWS認証、ツール、Pull Secret、SSH鍵、PKI、Hosted Zone、Quotaのいずれかを変更した場合は再実行します。

## Phase 1～2: Terraformネットワーク

作成対象はVPC、9 Subnet、Internet Gateway、NAT Gateway 1個、Elastic IP、Route Tableです。既存Public Hosted Zoneはdata sourceで読むだけです。

クリーンなstateの期待値は次です。

```text
Plan: 26 to add, 0 to change, 0 to destroy.
```

保存PlanをApplyした後、`scripts/01-validate-network.sh`が`Network validation PASSED.`となるまでPhase 3へ進みません。詳細と確認文字列は[04. Terraformネットワーク基盤](04-terraform-network.md)に従います。

## Phase 3: Client VPN

次の順序で実施します。

1. リポジトリ外でCA、server/client証明書を生成する。
2. server証明書とCA証明書をACMへimportする。
3. Terraformの追加7件だけをPlan/Applyする。
4. Windowsへ秘密鍵入り`.ovpn`を安全にimportする。
5. split tunnelとVPC routeを確認する。

基盤BINDが存在しない初期段階ではVPC Resolverを使用します。BIND完成後にPhase 5.5でDNSを切り替えます。Client VPNは2 AZへassociateしますが、VPNだけで本番用管理経路の可用性を保証するものではありません。

## Phase 4: 基盤EC2とロードバランサー

`scripts/07-plan-infrastructure.sh`で、Installer、DNS/NTP 2台、HAProxy 2台、Proxy/Registry、NFS、Internal NLBと関連リソースをPlanします。Planのactionを確認した後、`scripts/07b-apply-infrastructure.sh`でguardを再検査してApplyします。この段階ではOpenShiftノードを起動しません。

Planが既存ネットワークやClient VPNの更新・削除を含む場合は停止します。Apply後は`scripts/06-validate-infrastructure.sh`とInstallerへのSSHを確認します。

## Phase 5～5.5: 基盤サービスとVPN DNS

現在のWSLシェルへRegistryパスワードを設定し、次を順番に実行します。

```bash
cd "$LAB_ROOT"
bash scripts/08-ansible-preflight.sh
bash scripts/09-apply-infrastructure-services.sh
bash scripts/10-validate-infrastructure-services.sh
```

Registryパスワードは新しいシェルへ引き継がれません。再開時はパスワードマネージャーから同じ値を読み込み、`REGISTRY_PASSWORD`を再exportします。

基盤検証合格後にだけ、Client VPN DNSをBIND 2台へ更新します。

```bash
bash scripts/10a-plan-client-vpn-dns.sh
bash scripts/10b-apply-client-vpn-dns.sh
bash scripts/10c-validate-client-vpn-dns.sh
```

Apply時にVPNが切断される場合があります。Windowsで切断・再接続し、既定DNSと内部/外部名前解決も確認します。

## Phase 6: OpenShift UPI

通常の`terraform plan`や`terraform apply`を直接実行せず、[07. OpenShift UPIインストール](07-openshift-install.md)のスクリプト15～29を順番に使用します。

大きな流れは次です。

1. install-configとRHCOS AMIを検証する。
2. DHCP OptionsとNode用Security GroupをPlan/Applyする。
3. Manifest/Ignitionを生成し、内部HTTPへ一時配置する。
4. Bootstrap、Control Plane 3台、Worker 3台を起動する。
5. `bootstrap-complete`を待つ。
6. HAProxy/DNSからBootstrapを除外し、Bootstrap EC2だけを削除する。
7. CSRを1件ずつ確認・承認する。
8. `install-complete`を待ち、Ignition HTTPを停止する。
9. 6永久Node、Operator、API、Console、NLB、Terraform stateを検証する。

## Phase 7: 初期設定と障害試験

NFS StorageClass、HAProxy片系停止、Worker計画再起動は独立した検証です。各試験の`--preflight-only`を先に実行し、1件が完全復旧してrecovery markerが消えたことを確認してから次へ進みます。

Control Plane再起動、etcdバックアップ/リストア、disconnected化はこの配布版の手順に含まれません。

## 中断・再開の判断

| 中断位置 | 再開方法 |
|---|---|
| Apply前の保存Planだけ | AWS変更なし。Planを再レビューする。古ければ削除して同じplannerから作り直す |
| Phase 2～5.5の検証合格後 | 新しいシェルで`LAB_ROOT`、AWS認証、必要なsecret環境変数を再設定し、直前のvalidationから再開 |
| Ansible途中失敗 | 原因を修正し、preflight後に同じplaybookを再実行。AWSコンソールで補正しない |
| スクリプト15完了後、Ignition生成前 | Phase 6を再開可能 |
| Ignition生成後、Node起動前 | 生成から12時間以内に続行。超過したら古いIgnitionを再利用しない |
| Node起動後～Bootstrap削除 | 原則中断しない。失敗時はログを保全し、後続スクリプトを飛ばさない |
| Bootstrap削除後 | CSR確認から再開可能 |
| HAProxy/Worker試験中断 | Terraformを実行せず、各スクリプトの`--recover`を最優先する |

再開時に「現在どこまでstateへ作成されたか」が不明な場合、推測で後続コマンドを実行しません。次の読み取り確認を保存し、最後に合格したvalidationを再実行します。

```bash
aws sts get-caller-identity --profile openshift-lab
aws configure get region --profile openshift-lab
terraform -chdir="$LAB_ROOT/terraform" workspace show
terraform -chdir="$LAB_ROOT/terraform" state list
```

後続フェーズ完了後にPhase 1の素の`terraform plan`を再実行すると、enable変数の違いから削除を提案する可能性があります。再開時は各フェーズ専用plannerを使用します。

## 途中で構築を中止する場合

AWSリソースが1件でも作成済みなら、EC2やVPCをコンソールから個別削除しません。[08. 完全削除](08-validation-and-destroy.md#6-完全削除)へ進みます。障害試験のrecovery markerが残る場合は先に復旧します。

destroy plannerが現在の部分stateを受け付けない場合は、通常の`terraform destroy`へ切り替えず停止してください。配布版でサポートする部分構築状態と実装上の制約は、完全削除章の「部分構築からの中止」を参照します。

AWS cleanupを`scripts/14-validate-cleanup.sh`で検証した後だけ、`scripts/35-clean-local-artifacts.sh`でlocal資材をpreviewし、archiveまたは削除します。配布物はスクリプト90/92/91の検査後、作業treeを直接コピーせずrelease builderから作成します。
