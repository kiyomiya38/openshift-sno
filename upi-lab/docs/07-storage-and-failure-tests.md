# 07. StorageClassと障害試験

## この章の目的

クラスター完成後にNFS StorageClassを導入し、永続性を検証します。NFSの導入と検証は必須です。HAProxy片系停止試験とWorker計画再起動試験は任意です。過去の実行結果は[検証レポート](validation-report.md)に分離しており、この章は現在の環境状態を仮定しません。

以降は、特記がなければAWS Client VPNへ接続したWSL Ubuntuで実行します。

```bash
LAB_ROOT_FILE="$HOME/.config/openshift-upi-lab/lab-root"
if [[ ! -s "$LAB_ROOT_FILE" ]]; then
  echo 'ERROR: Saved lab path is missing. Repeat chapter 02 section 1.' >&2
else
  LAB_ROOT="$(<"$LAB_ROOT_FILE")"
  export LAB_ROOT
  if [[ ! -x "$LAB_ROOT/scripts/02-03-preflight.sh" ]]; then
    echo 'ERROR: Saved lab path is invalid. Repeat chapter 02 section 1.' >&2
    unset LAB_ROOT
  else
    cd "$LAB_ROOT"
    printf 'LAB_ROOT=%s\n' "$LAB_ROOT"
    echo 'PASS: WSL work context is ready.'
  fi
fi
unset LAB_ROOT_FILE
```

`PASS: WSL work context is ready.`が表示されない場合は、後続コマンドを実行せず02章の手順1へ戻ります。

## 1. クラスター完成検査

まず自動検査を実行します。

```bash
bash scripts/06-15-validate-openshift-cluster.sh
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
bash scripts/07-01-apply-nfs-storage.sh
```

対象API、Cluster ID、context、identityを確認し、次を正確に入力します。

```text
APPLY-NFS-STORAGE
```

`NFS StorageClass installation PASSED.`を確認します。

### 2.3 一時PVCで永続性を確認する

```bash
bash scripts/07-02-validate-nfs-storage.sh
```

確認文字列:

```text
RUN-NFS-PERSISTENCE-TEST
```

スクリプトは一時Namespace/PVC/Podを作成し、Pod再作成後も同じmarkerを読めることを検証します。合格時の一時PVCは調査用に残るため、必ず次の片付けまで実行します。

```bash
bash scripts/07-03-cleanup-nfs-storage-test.sh
```

確認文字列:

```text
DELETE-NFS-PERSISTENCE-TEST
```

`NFS persistence test cleanup PASSED.`となり、一時Pod、PVC、動的PV、Namespaceが消え、Provisioner、静的root PV/PVC、`nfs-rwx`が正常に残ることを確認します。

HAProxy片系停止試験とWorker計画再起動試験を行わない場合は、手順3と4を省略して手順5へ進みます。

## 3. HAProxy片系停止試験（任意）

この試験はHAProxy EC2を1台だけ停止して残る1台への収束を確認し、停止したEC2を必ず復旧します。2台を同時に停止しません。試験中はTerraform、Worker試験、手動のEC2/NLB操作を実行しません。

状態は次のリポジトリ外ファイルで管理されます。

```text
$HOME/.config/openshift-upi-lab/haproxy-failover-recovery.json
$HOME/.config/openshift-upi-lab/haproxy-failover.lock
```

### 3.1 1台ずつpreflightと実試験を行う

```bash
bash scripts/07-04-test-haproxy-failover.sh --preflight-only haproxy-0
```

`HAProxy failure-test preflight PASSED.`を確認してから実試験を行います。

```bash
bash scripts/07-04-test-haproxy-failover.sh haproxy-0
```

確認文字列は`TEST-HAPROXY-0-FAILOVER`です。合格後、両EC2がrunning、全4 Target Groupが`2/2 healthy`、`scripts/06-15-validate-openshift-cluster.sh`が`Failures: 0`、recovery markerが不存在であることを確認します。

完全復旧後だけ、同じ順序で2台目を試験します。

```bash
bash scripts/07-04-test-haproxy-failover.sh --preflight-only haproxy-1
```

`HAProxy failure-test preflight PASSED.`を確認してから実試験を行います。

```bash
bash scripts/07-04-test-haproxy-failover.sh haproxy-1
```

確認文字列は`TEST-HAPROXY-1-FAILOVER`です。NLB health checkとデータプレーンの収束には60秒以上かかる場合があります。

### 3.2 異常中断を復旧する

端末やPCの停止でrecovery markerが残った場合、新しい試験やTerraformを実行せず、最初に復旧モードを実行します。

```bash
bash scripts/07-04-test-haproxy-failover.sh --recover
```

画面に表示された`RECOVER-HAPROXY-0`または`RECOVER-HAPROXY-1`を正確に入力します。AWSアカウント、リージョン、workspace、Instance IDが一致し、両HAProxyとOpenShiftの完全復旧を検証できた場合だけmarkerが削除されます。

復旧モードが失敗した場合、markerを手動削除したり、もう1台を起動・停止したりしません。次を読み取り、管理者へ渡します。

```bash
jq '{target_name,target_instance_id,account_id,region,terraform_workspace}' \
  "$HOME/.config/openshift-upi-lab/haproxy-failover-recovery.json"
```

## 4. Worker計画再起動試験（任意）

`scripts/07-05-test-worker-reboot.sh`はWorkerだけを対象に、cordon、PDBを尊重したdrain、AWS reboot、`bootID`変更、Ready/MCO/Operatorの収束、uncordonを検証します。Control Planeは受け付けません。

試験順序は、NFS Provisioner配置とAZを考慮して固定されています。

1. `worker-0`
2. `worker-2`
3. `worker-1`

対象ごとにpreflightと実試験を分けます。

```bash
bash scripts/07-05-test-worker-reboot.sh --preflight-only worker-0
```

`Worker reboot-test preflight PASSED.`を確認してから実試験を行います。

```bash
bash scripts/07-05-test-worker-reboot.sh worker-0
```

確認文字列は対象に対応する`TEST-WORKER-0-REBOOT`、`TEST-WORKER-2-REBOOT`、`TEST-WORKER-1-REBOOT`です。Instance ID、固定IP、Node UIDを維持したまま`bootID`が変わり、対象がReadyかつschedulableへ戻った場合だけ次へ進みます。

```bash
bash scripts/07-05-test-worker-reboot.sh --preflight-only worker-2
```

`worker-2`のpreflight合格後に実行します。

```bash
bash scripts/07-05-test-worker-reboot.sh worker-2
```

`worker-2`の完全復旧を確認してから、`worker-1`のpreflightを実行します。

```bash
bash scripts/07-05-test-worker-reboot.sh --preflight-only worker-1
```

`worker-1`のpreflight合格後に実行します。

```bash
bash scripts/07-05-test-worker-reboot.sh worker-1
```

### 4.1 異常中断を復旧する

次のmarkerが存在する場合、新しい再起動要求を送らず復旧します。

```text
$HOME/.config/openshift-upi-lab/worker-reboot-recovery.json
```

```bash
bash scripts/07-05-test-worker-reboot.sh --recover
```

画面に表示される対象別`RECOVER-WORKER-*`を正確に入力します。Pending CSRがある場合は`scripts/06-13-review-csrs.sh`で個別確認し、再度`--recover`を実行します。復旧成功は可用性を戻した結果であり、中断した試験の合格にはなりません。同じ対象を新しいpreflightから再試験します。

Control Planeの再起動とetcd backup/restoreは別設計が必要で、この配布版の試験対象外です。特に初回証明書ローテーション前のetcdバックアップを復旧用として扱いません。

## 5. この章の終了条件

任意試験を省略した場合も、完全削除や別作業へ進む前に次の検査を必ず実行します。

```bash
STATE_DIR="$HOME/.config/openshift-upi-lab"
find "$STATE_DIR" -maxdepth 1 -type f \
  \( -name '*-recovery.json' -o -name '*.lock' \) -print
bash scripts/06-15-validate-openshift-cluster.sh
```

recovery JSONが表示された場合は対応する`--recover`を実行します。lockファイルは通常存在してもflockが解放済みの場合がありますが、別プロセスが実行中でないことを確認します。完成検査が`Failures: 0`になるまでdestroyへ進みません。

## 次へ

必須のNFS検証を完了し、実施した任意試験がすべて完全復旧したことを確認します。環境を終了する場合は[08. 完全削除](08-destroy.md)へ進みます。
