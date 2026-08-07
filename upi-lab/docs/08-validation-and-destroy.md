# 08. 検証と完全削除

## この章の目的

クラスター、DNS、ロードバランサー、ストレージ、計画保守を検証し、利用終了時にはAWSリソースとローカル機微情報を区別して片付けます。過去の実行結果は[検証レポート](validation-report.md)に分離しており、この章は現在の環境状態を仮定しません。

以降は、特記がなければAWS Client VPNへ接続したWSL Ubuntuで実行します。

```bash
cd "$LAB_ROOT"
```

## 1. クラスター完成検査

まず自動検査を実行します。

```bash
bash scripts/29-validate-openshift-cluster.sh
```

合格時は次が表示されます。

```text
Failures: 0
OpenShift cluster validation PASSED.
```

主な検査対象は次です。

- 永久Node 6台が`Ready`。
- ClusterVersionが`Available`。
- 全ClusterOperatorがAvailableで、Progressing/Degradedではない。
- Pending CSRがない。
- APIとConsole RouteへClient VPN経由で到達できる。
- 4つのNLB Target GroupでHAProxy 2台がhealthy。
- Terraform stateに永久Node 6台だけがあり、Bootstrapがない。

必要に応じて、同じkubeconfigで読み取り確認します。

```bash
export KUBECONFIG="$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig"
oc get nodes -o wide
oc get clusterversion
oc get clusteroperators
oc get csr

dig api.ocp.lab.k8study.com A
dig api-int.ocp.lab.k8study.com A
curl -k https://api.ocp.lab.k8study.com:6443/readyz
curl -kI https://console-openshift-console.apps.ocp.lab.k8study.com
```

一時的にOperatorがProgressingの場合は状態が収束してから再検査します。理由を確認せず障害試験へ進みません。

## 2. NFS StorageClassと永続性

### 2.1 設計上の制限

基盤NFS `10.80.40.41:/srv/nfs/openshift`を、専用の静的root PV/PVCからNFS Subdir External Provisionerへ公開します。Provisionerは`restricted-v2` SCCと非root UIDで稼働し、非defaultの`nfs-rwx` StorageClassを提供します。

この構成には次の制限があります。

- NFSサーバーは1台で、本番ストレージの代替ではない。
- Kubernetes上の要求容量はNFS quotaとして強制されない。
- Volume expansionとsnapshotは対象外。
- NFS root EBSと全データはTerraform完全削除時に失われる。

### 2.2 導入する

```bash
bash scripts/30-apply-nfs-storage.sh
```

対象API、Cluster ID、context、identityを確認し、次を正確に入力します。

```text
APPLY-NFS-STORAGE
```

`NFS StorageClass installation PASSED.`を確認します。

### 2.3 一時PVCで永続性を確認する

```bash
bash scripts/31-validate-nfs-storage.sh
```

確認文字列:

```text
RUN-NFS-PERSISTENCE-TEST
```

スクリプトは一時Namespace/PVC/Podを作成し、Pod再作成後も同じmarkerを読めることを検証します。合格時の一時PVCは調査用に残るため、必ず次の片付けまで実行します。

```bash
bash scripts/32-cleanup-nfs-storage-test.sh
```

確認文字列:

```text
DELETE-NFS-PERSISTENCE-TEST
```

`NFS persistence test cleanup PASSED.`となり、一時Pod、PVC、動的PV、Namespaceが消え、Provisioner、静的root PV/PVC、`nfs-rwx`が正常に残ることを確認します。

## 3. HAProxy片系停止試験

この試験はHAProxy EC2を1台だけ停止して残る1台への収束を確認し、停止したEC2を必ず復旧します。2台を同時に停止しません。試験中はTerraform、Worker試験、手動のEC2/NLB操作を実行しません。

状態は次のリポジトリ外ファイルで管理されます。

```text
$HOME/.config/openshift-upi-lab/haproxy-failover-recovery.json
$HOME/.config/openshift-upi-lab/haproxy-failover.lock
```

### 3.1 1台ずつpreflightと実試験を行う

```bash
bash scripts/33-test-haproxy-failover.sh --preflight-only haproxy-0
```

`HAProxy failure-test preflight PASSED.`を確認してから実試験を行います。

```bash
bash scripts/33-test-haproxy-failover.sh haproxy-0
```

確認文字列は`TEST-HAPROXY-0-FAILOVER`です。合格後、両EC2がrunning、全4 Target Groupが`2/2 healthy`、スクリプト29が`Failures: 0`、recovery markerが不存在であることを確認します。

完全復旧後だけ、同じ順序で2台目を試験します。

```bash
bash scripts/33-test-haproxy-failover.sh --preflight-only haproxy-1
bash scripts/33-test-haproxy-failover.sh haproxy-1
```

確認文字列は`TEST-HAPROXY-1-FAILOVER`です。NLB health checkとデータプレーンの収束には60秒以上かかる場合があります。

### 3.2 異常中断を復旧する

端末やPCの停止でrecovery markerが残った場合、新しい試験やTerraformを実行せず、最初に復旧モードを実行します。

```bash
bash scripts/33-test-haproxy-failover.sh --recover
```

画面に表示された`RECOVER-HAPROXY-0`または`RECOVER-HAPROXY-1`を正確に入力します。AWSアカウント、リージョン、workspace、Instance IDが一致し、両HAProxyとOpenShiftの完全復旧を検証できた場合だけmarkerが削除されます。

復旧モードが失敗した場合、markerを手動削除したり、もう1台を起動・停止したりしません。次を読み取り、管理者へ渡します。

```bash
jq '{target_name,target_instance_id,account_id,region,terraform_workspace}' \
  "$HOME/.config/openshift-upi-lab/haproxy-failover-recovery.json"
```

## 4. Worker計画再起動試験

スクリプト34はWorkerだけを対象に、cordon、PDBを尊重したdrain、AWS reboot、`bootID`変更、Ready/MCO/Operatorの収束、uncordonを検証します。Control Planeは受け付けません。

試験順序は、NFS Provisioner配置とAZを考慮して固定されています。

1. `worker-0`
2. `worker-2`
3. `worker-1`

対象ごとにpreflightと実試験を分けます。

```bash
bash scripts/34-test-worker-reboot.sh --preflight-only worker-0
bash scripts/34-test-worker-reboot.sh worker-0
```

確認文字列は対象に対応する`TEST-WORKER-0-REBOOT`、`TEST-WORKER-2-REBOOT`、`TEST-WORKER-1-REBOOT`です。Instance ID、固定IP、Node UIDを維持したまま`bootID`が変わり、対象がReadyかつschedulableへ戻った場合だけ次へ進みます。

```bash
bash scripts/34-test-worker-reboot.sh --preflight-only worker-2
bash scripts/34-test-worker-reboot.sh worker-2

bash scripts/34-test-worker-reboot.sh --preflight-only worker-1
bash scripts/34-test-worker-reboot.sh worker-1
```

### 4.1 異常中断を復旧する

次のmarkerが存在する場合、新しい再起動要求を送らず復旧します。

```text
$HOME/.config/openshift-upi-lab/worker-reboot-recovery.json
```

```bash
bash scripts/34-test-worker-reboot.sh --recover
```

画面に表示される対象別`RECOVER-WORKER-*`を正確に入力します。Pending CSRがある場合はスクリプト27で個別確認し、再度`--recover`を実行します。復旧成功は可用性を戻した結果であり、中断した試験の合格にはなりません。同じ対象を新しいpreflightから再試験します。

Control Planeの再起動とetcd backup/restoreは別設計が必要で、この配布版の試験対象外です。特に初回証明書ローテーション前のetcdバックアップを復旧用として扱いません。

## 5. 障害試験の終了条件

完全削除や別試験へ進む前に、次を確認します。

```bash
STATE_DIR="$HOME/.config/openshift-upi-lab"
find "$STATE_DIR" -maxdepth 1 -type f \
  \( -name '*-recovery.json' -o -name '*.lock' \) -print
bash scripts/29-validate-openshift-cluster.sh
```

recovery JSONが表示された場合は対応する`--recover`を実行します。lockファイルは通常存在してもflockが解放済みの場合がありますが、別プロセスが実行中でないことを確認します。完成検査が`Failures: 0`になるまでdestroyへ進みません。

## 6. 完全削除

ここでいう完全削除は、次の3段階です。

1. Terraform管理AWSリソースのdestroy。
2. Terraform外でimportしたACM証明書の削除と、AWS残存検査。
3. 用途に応じたローカル機微情報、VPN profile、AWS credentialの処理。

既存の`lab.k8study.com` Public Hosted Zoneは保持します。ラボと無関係なリソースを削除しません。

### 6.1 データ消失と対象を確認する

destroyにより、OpenShift etcd、NFS、Registry、全EC2/EBS、Client VPN、NLB、VPCが失われます。必要なアプリケーションデータ、マニフェスト、監査記録をリポジトリ外の安全な場所へ退避します。秘密情報を通常の作業ログへコピーしません。

次を確認します。

- NFS永続性テストの一時資材をスクリプト32で片付けた。
- HAProxy/Worker recovery markerがなく、障害試験が実行中でない。
- 他の作業者がTerraformやAWSコンソールを操作していない。
- 現在のlocal stateが、このラボの唯一の正本である。
- 削除後も必要なデータがない、または退避を検証済み。

### 6.2 AWS identity、workspace、stateを確認する

承認済みAccount IDを新しいシェルへ再設定してから確認します。

```bash
cd "$LAB_ROOT"
export EXPECTED_AWS_ACCOUNT_ID='<承認済みの12桁Account ID>'

test "$(aws sts get-caller-identity \
  --profile openshift-lab --query Account --output text)" \
  = "$EXPECTED_AWS_ACCOUNT_ID"
test "$(aws configure get region --profile openshift-lab)" \
  = 'ap-northeast-3'
test "$(terraform -chdir=terraform workspace show)" = 'default'
terraform -chdir=terraform state list
```

Account、region、workspaceが違う場合は中止します。stateが空なのにAWSリソースが存在する場合も、destroyを続けずstate復旧を行います。

### 6.3 destroy Planを作成する

```bash
bash scripts/11-plan-destroy.sh
```

削除数は完了したフェーズにより変わるため、文書の固定値と照合しません。Planが`delete`と`no-op`だけであり、既存Public Hosted Zoneや無関係リソースを含まないことをresource address単位でレビューします。`create`、`update`、`replace`が1件でもあればApplyしません。

スクリプトはPlan時点のAccount、region、workspace、state lineage/serial、Plan SHA-256をguard metadataへ保存します。部分構築からの中止も同じplannerを使用します。plannerが現在のstateを受け付けない場合、素の`terraform destroy`へ切り替えず停止します。

#### 部分構築からの中止

スクリプト11は、Networkだけ、Client VPNまで、基盤サービスまで、OpenShift構築途中を含め、state内の許可されたラボresourceを列挙します。現在のmanaged件数とdelete件数が完全一致し、他actionがない場合だけPlanを保存します。したがって完成時の固定削除数を成功条件にしません。

ACM証明書をまだimportしていない段階でも、登録済みexpected Account IDからidentityを検証してTerraform resourceを削除できます。Terraform stateが既に空ならdestroy Planを作らず、スクリプト13の証明書確認へ案内します。

### 6.4 WindowsのClient VPNを切断する

destroy Planを作成・レビューした後、WindowsのAWS VPN Clientで`openshift-upi-lab`を`Disconnect`します。AWS APIは通常のインターネット経路から利用できることを確認します。接続中のVPN Endpointを削除すると管理経路が突然切れ、端末側の表示が不明瞭になります。

VPN切断後はOpenShift/Private IPへ到達できなくなるため、退避やクラスター検査は先に完了させます。

### 6.5 保存済みdestroy PlanをApplyする

```bash
bash scripts/12-apply-destroy.sh
```

Plan作成後にstate、AWS接続先、workspace、Planが変わるとスクリプトは拒否します。その場合は古いPlanを使用せずスクリプト11から作り直します。

削除対象を再確認し、次を正確に入力します。

```text
DESTROY-OPENSHIFT-UPI-LAB
```

成功後、使用済みdestroy Planとguard metadataは削除されます。途中失敗時はAWSコンソールで補正せず、エラーとstateを確認してスクリプト11から再Planします。

### 6.6 ACM証明書を削除する

Terraform destroy成功後に実行します。

```bash
bash scripts/13-delete-client-vpn-certificate.sh
```

スクリプトがラボtag、Account/region、`InUseBy: []`を検証した後、次を正確に入力します。

```text
DELETE-LAB-CERTIFICATE
```

成功時はACM証明書とローカルARNファイルだけが削除され、CA/server/client証明書と秘密鍵は保持されます。

### 6.7 AWS残存リソースを検査する

```bash
bash scripts/14-validate-cleanup.sh
```

このスクリプトは、空のTerraform state、Project tag、EC2/EBS/EIP/NAT、Client VPN、VPC、Security Group/rule、DHCP Options、NLB/Target Group/ENI、CloudWatch Logs、IAM Role/Instance Profile、EC2 Key Pair、ACM証明書を確認し、既存Public Hosted Zoneが保持されていることを検証します。

```text
=== Cleanup Result ===
Failures: 0
Cleanup validation PASSED. No lab resources were found.
```

Resource Groups Tagging APIは削除済みARNを一時的に返す場合があります。スクリプトが直接APIとの照合でwarningとして処理した場合を除き、`Failures: 1`以上を無視しません。AWS残存検査が合格するまでlocal stateを削除しません。

### 6.8 ローカル資材をpreviewする

スクリプト14の合格時に作成されたcleanup marker、空のstate、state identity、`default` workspace、destroy Plan不存在、recovery marker/active lock不存在を照合してから、対象だけを表示します。既定動作は読み取り専用です。

```bash
cd "$LAB_ROOT"
bash scripts/35-clean-local-artifacts.sh
```

対象は、repository内の`.terraform/`、state/backup、Plan/metadata、logs/artifacts、およびlocalのinstall assets、`cluster.env`、client config、cluster stage、試験結果、cache、cleanup markerです。

既定では次を保持します。

- Client VPN PKI
- SSH秘密鍵/公開鍵
- Pull Secret
- 登録済みexpected Account ID
- AWS CLI profileとIAM access key

### 6.9 ローカル資材を隔離または削除する

復旧可能な方法を優先する場合は、選択された資材をrepository外の権限`700`ディレクトリへ移動します。

```bash
bash scripts/35-clean-local-artifacts.sh --archive
```

対象とarchive destinationを確認し、次を正確に入力します。

```text
ARCHIVE-LOCAL-LAB-ARTIFACTS
```

退避不要で、AWS cleanupの証拠を別途記録済みの場合だけ永久削除を選びます。

```bash
bash scripts/35-clean-local-artifacts.sh --delete
```

確認文字列:

```text
DELETE-LOCAL-LAB-ARTIFACTS
```

PKIも対象へ含めるには`--include-pki`を明示します。まずpreviewまたはarchiveで対象を確認します。

```bash
bash scripts/35-clean-local-artifacts.sh --include-pki
bash scripts/35-clean-local-artifacts.sh --archive --include-pki
```

`--delete --include-pki`はClient VPN CA、server/client秘密鍵を永久削除し、次回はPKI再生成とWindows profile再登録が必要になる不可逆操作です。端末撤去など明確な目的がある場合だけ使用します。

```bash
bash scripts/35-clean-local-artifacts.sh --delete --include-pki
```

いずれのモードでもSSH鍵、Pull Secret、expected Account ID、AWS CLI credentialは削除しません。Windows AWS VPN ClientのprofileとWindowsへコピーした`.ovpn`は手動で削除します。ラボ専用IAM access keyを廃止する場合はAWS側で無効化・削除してから、`~/.aws/credentials`のprofileを安全に処理します。

### 6.10 配布物を監査・作成する

作業ディレクトリをZIP化しません。ローカルcleanup後、まず静的検査と非破壊auditを実行します。

```bash
cd "$LAB_ROOT"
bash scripts/90-static-validation.sh
bash scripts/92-test-release-builder.sh
bash scripts/91-build-release.sh --audit-only
```

`scripts/92-test-release-builder.sh`は一時fixture上でrelease builderを2回実行し、archiveの再現性、checksum、禁止ファイルと秘密鍵fixtureの拒否を検査します。source treeやAWSは変更しません。auditはstate、Plan、logs、secret、private key、kubeconfig、Ignition、個人パス、具体的なAccount IDを検出した場合に失敗します。値は表示せず、問題のファイル名だけを報告します。

配布archiveは`upi-lab`外の新規出力ディレクトリへ作成します。

```bash
mkdir -p "$HOME/openshift-upi-lab-release"
bash scripts/91-build-release.sh "$HOME/openshift-upi-lab-release"
```

スクリプトはsource treeを変更せず、許可リスト対象だけをstageし、`openshift-upi-lab-source.tar.gz`とSHA-256ファイルを作成します。既存archiveを上書きしません。配布前にchecksumを検証し、archiveを展開してREADME、LICENSE、SECURITY、第三者noticeが含まれることを確認します。

## 7. 完了条件

- `scripts/14-validate-cleanup.sh`が`Failures: 0`。
- Terraform stateにmanaged resourceがない。
- Client VPN用ACM証明書とローカルARNファイルがない。
- 既存Public Hosted Zoneと他用途リソースが保持されている。
- Windows AWS Client VPNが切断され、保持/削除するprofileとPKIを判断済み。
- recovery markerが残っていない。
- クラスター固有資材を次回構築へ再利用しない。
- 配布物にstate、Plan、provider cache、ログ、secret、kubeconfig、Ignitionが含まれない。
- 配布時はスクリプト90、92、91のauditが合格し、クリーンなrelease archiveから配布する。
