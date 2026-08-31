# 08. 完全削除

## この章の目的

ここでいう完全削除は、次の3段階です。

1. Terraform管理AWSリソースのdestroy。
2. Terraform外でimportしたACM証明書の削除と、AWS残存検査。
3. Windowsへ登録したラボIngress CAと、用途に応じたローカル機微情報、VPN profile、AWS credentialの処理。

既存の`lab.k8study.com` Public Hosted Zoneは保持します。ラボと無関係なリソースを削除しません。

## 1. データ消失と対象を確認する

destroyにより、OpenShift etcd、NFS、Registry、全EC2/EBS、Client VPN、NLB、VPCが失われます。必要なアプリケーションデータ、マニフェスト、監査記録をリポジトリ外の安全な場所へ退避します。秘密情報を通常の作業ログへコピーしません。

次を確認します。

- NFS永続性テストを実施した場合は、一時資材を`scripts/07-03-cleanup-nfs-storage-test.sh`で片付けた。
- HAProxy/Worker recovery markerがなく、障害試験が実行中でない。
- 他の作業者がTerraformやAWSコンソールを操作していない。
- 現在のlocal stateが、このラボの唯一の正本である。
- 削除後も必要なデータがない、または退避を検証済み。

## 2. AWS identity、workspace、stateを確認する

保存済みaccount guard、現在のAWS login、region、workspaceを構築前検査で再確認します。Account IDは初回登録時のguardから自動取得するため再入力しません。

```bash
LAB_ROOT_FILE="$HOME/.config/openshift-upi-lab/lab-root"
LAB_CONTEXT_READY=false
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
    LAB_CONTEXT_READY=true
  fi
fi
unset LAB_ROOT_FILE

if [[ "$LAB_CONTEXT_READY" == true ]]; then
  bash scripts/02-03-preflight.sh
  terraform -chdir=terraform state list
else
  echo 'STOP: Cleanup prerequisite validation was not started.' >&2
fi
unset LAB_CONTEXT_READY
```

`PASS: WSL work context is ready.`が表示されない場合は、後続コマンドを実行せず02章の手順1へ戻ります。`Failures: 0`、`Warnings: 0`、`Preflight PASSED`の場合だけ続行します。Account、region、workspaceが違う場合は中止します。stateが空なのにAWSリソースが存在する場合も、destroyを続けずstate復旧を行います。

## 3. destroy Planを作成する

```bash
bash scripts/08-01-plan-destroy.sh
```

削除数は完了した工程により変わるため、文書の固定値と照合しません。Planが`delete`と`no-op`だけであり、既存Public Hosted Zoneや無関係リソースを含まないことをresource address単位でレビューします。`create`、`update`、`replace`が1件でもあればApplyしません。

スクリプトはPlan時点のAccount、region、workspace、state lineage/serial、Plan SHA-256をguard metadataへ保存します。部分構築からの中止も同じplannerを使用します。plannerが現在のstateを受け付けない場合、素の`terraform destroy`へ切り替えず停止します。

### 3.1 部分構築からの中止

`scripts/08-01-plan-destroy.sh`は、Networkだけ、Client VPNまで、基盤サービスまで、OpenShift構築途中を含め、state内の許可されたラボresourceを列挙します。現在のmanaged件数とdelete件数が完全一致し、他actionがない場合だけPlanを保存します。したがって完成時の固定削除数を成功条件にしません。

ACM証明書をまだimportしていない段階でも、登録済みexpected Account IDからidentityを検証してTerraform resourceを削除できます。Terraform stateが既に空ならdestroy Planを作らず、`scripts/08-03-delete-client-vpn-certificate.sh`の証明書確認へ案内します。

stateが空でplannerから証明書確認へ案内された場合に限り、手順4～6を省略して手順7へ進みます。Planが存在しない状態で手順4や6を実行しません。

## 4. 保存済みdestroy Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color destroy.tfplan
```

表示された全resource addressがこのラボの削除対象で、managed actionが`delete`または`no-op`だけであることを人手で確認します。既存Public Hosted Zone、他環境のリソース、`create`、`update`、`replace`が含まれる場合や、Planファイルが存在しない場合は先へ進みません。

## 5. WindowsのClient VPNを切断する

destroy Planを作成・レビューした後、WindowsのAWS VPN Clientで`openshift-upi-lab`を`Disconnect`します。AWS APIは通常のインターネット経路から利用できることを確認します。接続中のVPN Endpointを削除すると管理経路が突然切れ、端末側の表示が不明瞭になります。

VPN切断後はOpenShift/Private IPへ到達できなくなるため、退避やクラスター検査は先に完了させます。

Windows側が「切断済み」になっても、AWS側の接続状態がしばらく`active`または`terminating`のことがあります。WSLで次を実行し、削除を妨げる`terminated`以外の接続がないことを読み取り専用で確認します。

```bash
ENDPOINT_ID="$(terraform -chdir="$LAB_ROOT/terraform" output -raw client_vpn_endpoint_id)"

aws ec2 describe-client-vpn-connections \
  --client-vpn-endpoint-id "$ENDPOINT_ID" \
  --profile openshift-lab \
  --region ap-northeast-3 \
  --query 'Connections[?Status.Code!=`terminated`].{ConnectionId:ConnectionId,Status:Status.Code,StatusMessage:Status.Message,ClientIp:ClientIp,CommonName:CommonName,EstablishedTime:ConnectionEstablishedTime}' \
  --output table
```

表が空なら手順6へ進みます。`terminating`はAWS側で切断処理中のため、追加操作をせず待ってから同じ確認を再実行します。`terminated`の履歴は最大60分間表示されることがありますが、手順6の安全ゲートは`terminated`を残存接続として数えません。`failed-to-terminate`なら終了処理が失敗しているため、StatusMessageを記録し、次の照合付き終了処理を1回再実行します。再び`failed-to-terminate`になった場合はdestroyへ進まず、IAM権限とAWS APIのエラーを調査します。

Windows側で確実に切断済みなのに同じ接続が`active`のまま残る場合、または状態が`failed-to-terminate`の場合だけ、上の表に表示された**1件のConnectionId**を引数へ指定します。次の専用モードは、保存済みPlanのAccount、region、workspace、state lineage/serial、Plan SHA-256とEndpoint IDを再検証します。指定したIDが、そのEndpointに属する`active`または`failed-to-terminate`の接続1件と一致しなければ終了処理を行いません。destroy Applyも行いません。

```bash
read -r -p 'ConnectionId shown in the table: ' CONNECTION_ID
bash scripts/08-02-apply-destroy.sh --terminate-connection "$CONNECTION_ID"
unset CONNECTION_ID
```

たとえば表のIDが`cvpn-connection-0123456789abcdef0`なら、末尾をその値へ置き換えます。スクリプトが接続情報を再表示した後、`TERMINATE-cvpn-connection-0123456789abcdef0`の形式で表示どおり入力します。

終了APIの直後は`terminating`になります。最初の読み取り専用コマンドを再実行し、`terminated`以外の表が空になるまで待ちます。ここまでの接続確認・終了ではTerraform stateと保存済みdestroy Planは変わらないため、再Planは不要です。確認後は`unset ENDPOINT_ID`を実行します。

## 6. 保存済みdestroy PlanをApplyする

```bash
bash scripts/08-02-apply-destroy.sh
```

Plan作成後にstate、AWS接続先、workspace、Planが変わるとスクリプトは拒否します。その場合は古いPlanを適用しません。[保存済みPlanの明示破棄](#61-staleまたは不採用のdestroy-planを明示破棄する)を行ってから`scripts/08-01-plan-destroy.sh`で作り直します。

`non-terminated Client VPN connection(s) remain`で停止した場合、Terraform Applyはまだ開始されておらず、保存済みPlanも変更されていません。手順5で接続状態を解消してから、この同じコマンドを再実行します。旧版スクリプトの`active or terminating Client VPN connection(s) remain`も同じ意味です。

削除対象を再確認し、次を正確に入力します。

```text
DESTROY-OPENSHIFT-UPI-LAB
```

成功後、使用済みdestroy Planとguard metadataは削除されます。Terraform Apply開始後に途中失敗した場合はAWSコンソールで補正せず、エラーとstateを確認して`scripts/08-01-plan-destroy.sh`から再Planします。Apply開始前の安全ゲートで停止しただけなら、表示された原因を解消して同じ保存済みPlanを再利用します。

### 6.1 staleまたは不採用のdestroy Planを明示破棄する

手順4のレビューでPlanを不採用にした場合、または手順6がguard不一致を報告した場合だけ実行します。固定された`destroy.tfplan`と`destroy.tfplan.meta`だけを削除し、AWSとTerraform stateは変更しません。

```bash
bash scripts/08-01-plan-destroy.sh --discard-saved-plan
```

表示された2つの絶対パスが`$LAB_ROOT/terraform`配下であることを確認し、次を正確に入力します。

```text
DISCARD-SAVED-DESTROY-PLAN
```

破棄後は手順3で新しいPlanを作成し、手順4からレビューし直します。Client VPN接続ゲートで停止しただけの場合はPlanがstaleではないため、この操作を行いません。

## 7. ACM証明書を削除する

Terraform destroy成功後に実行します。

```bash
bash scripts/08-03-delete-client-vpn-certificate.sh
```

スクリプトがラボtag、Account/region、`InUseBy: []`を検証した後、次を正確に入力します。

```text
DELETE-LAB-CERTIFICATE
```

成功時はACM証明書とローカルARNファイルだけが削除され、CA/server/client証明書と秘密鍵は保持されます。

## 8. AWS残存リソースを検査する

```bash
bash scripts/08-04-validate-cleanup.sh
```

このスクリプトは、空のTerraform state、Project tag、EC2/EBS/EIP/NAT、Client VPN、VPC、Security Group/rule、DHCP Options、NLB/Target Group/ENI、CloudWatch Logs、IAM Role/Instance Profile、EC2 Key Pair、ACM証明書を確認し、既存Public Hosted Zoneが保持されていることを検証します。

```text
=== Cleanup Result ===
Failures: 0
Cleanup validation PASSED. No lab resources were found.
```

Resource Groups Tagging APIは削除済みARNを一時的に返す場合があります。スクリプトが直接APIとの照合でwarningとして処理した場合を除き、`Failures: 1`以上を無視しません。AWS残存検査が合格するまでlocal stateを削除しません。

### 8.1 Windowsへ登録したラボIngress CAを削除する

[06. OpenShift 4.21 UPIインストール](06-openshift-install.md)でIngress CAをWindowsへ登録した場合だけ、Windows PowerShellでひとまとまりのコードとして実行します。

```powershell
$IngressCaPath = Read-Host 'Paste the Windows certificate path printed by WSL during chapter 06'

if (-not (Test-Path -LiteralPath $IngressCaPath -PathType Leaf)) {
  Write-Output "Ingress CA file was not found; verify the recorded Thumbprint manually: $IngressCaPath"
}

if (Test-Path -LiteralPath $IngressCaPath -PathType Leaf) {
  $IngressCa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($IngressCaPath)
  $CertStorePath = "Cert:\CurrentUser\Root\$($IngressCa.Thumbprint)"

  if (-not (Test-Path -LiteralPath $CertStorePath)) {
    Write-Output 'The OpenShift UPI lab Ingress CA is not present in the current-user trust store.'
  }

  if (Test-Path -LiteralPath $CertStorePath) {
    Get-Item -LiteralPath $CertStorePath |
      Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter

    $Confirmation = Read-Host 'Type REMOVE-OPENSHIFT-UPI-LAB-INGRESS-CA to continue'
    if ($Confirmation -eq 'REMOVE-OPENSHIFT-UPI-LAB-INGRESS-CA') {
      Remove-Item -LiteralPath $CertStorePath
    }

    if ($Confirmation -ne 'REMOVE-OPENSHIFT-UPI-LAB-INGRESS-CA') {
      Write-Output 'Certificate removal cancelled.'
    }
  }

  if (Test-Path -LiteralPath $CertStorePath) {
    throw "The lab Ingress CA is still trusted: $CertStorePath"
  }

  Write-Output 'PASS: The lab Ingress CA is absent from the current-user trust store.'
}
```

削除前にSubject、Issuer、Thumbprintが06章で登録した証明書と一致することを確認します。削除対象は`CurrentUser`の該当Thumbprint 1件だけです。公開証明書ファイルは次のlocal cleanupまで残るため、誤って削除した場合は再登録できます。証明書を登録していない場合は削除操作を行いません。

## 9. ローカル資材をpreviewする

`scripts/08-04-validate-cleanup.sh`の合格時に作成されたcleanup marker、空のstate、state identity、`default` workspace、destroy Plan不存在、recovery marker/active lock不存在を照合してから、対象だけを表示します。既定動作は読み取り専用です。

```bash
cd "$LAB_ROOT"
bash scripts/08-05-clean-local-artifacts.sh
```

対象は、repository内の`.terraform/`、state/backup、Plan/metadata、logs/artifacts、およびlocalのinstall assets、`cluster.env`、client config、cluster stage、試験結果、cache、cleanup markerです。

既定では次を保持します。

- Client VPN PKI
- SSH秘密鍵/公開鍵
- Pull Secret
- 登録済みexpected Account ID
- 次回のWSLセッションで使用する検証済みlab path
- AWS CLI profileとIAM access key

## 10. ローカル資材を隔離または削除する

`--archive`と`--delete`は同じ対象に対する**択一の最終操作**です。隔離して保持するなら`--archive`、退避不要なら`--delete`のどちらか1つだけを選びます。`--archive`成功後はcleanup markerもアーカイブへ移るため、元のパスに対して続けて`--delete`や`--include-pki`を実行すると安全停止します。これは期待動作です。

復旧可能な方法を優先する場合は、選択された資材をrepository外の権限`700`ディレクトリへ移動します。

```bash
bash scripts/08-05-clean-local-artifacts.sh --archive
```

対象とarchive destinationを確認し、次を正確に入力します。

```text
ARCHIVE-LOCAL-LAB-ARTIFACTS
```

成功時に表示されたarchive destinationを作業記録へ残します。この時点で元のローカル生成物に対するクリーンアップは完了です。同じ対象へ`--delete`を続けて実行しません。

退避不要で、AWS cleanupの証拠を別途記録済みの場合だけ永久削除を選びます。

```bash
bash scripts/08-05-clean-local-artifacts.sh --delete
```

確認文字列:

```text
DELETE-LOCAL-LAB-ARTIFACTS
```

PKIも対象へ含める場合は、最初のpreviewと選択した最終操作の両方で`--include-pki`を明示します。

```bash
bash scripts/08-05-clean-local-artifacts.sh --include-pki
bash scripts/08-05-clean-local-artifacts.sh --archive --include-pki
```

`--delete --include-pki`はClient VPN CA、server/client秘密鍵を永久削除し、次回はPKI再生成とWindows profile再登録が必要になる不可逆操作です。端末撤去など明確な目的がある場合だけ使用します。

```bash
bash scripts/08-05-clean-local-artifacts.sh --delete --include-pki
```

### 10.1 アーカイブ後に保持PKIを同じ場所へ隔離する

すでに`--archive`をPKIなしで完了した場合、PKIは元の`~/.config/openshift-upi-lab/pki`に保持されています。次回構築で再利用するなら追加操作は不要です。後から同じアーカイブへPKIも隔離する場合だけ、成功時に表示されたタイムスタンプ形式のarchive IDを入力します。

```bash
read -r -p 'Archive ID in YYYYMMDD-HHMMSS format: ' ARCHIVE_ID
bash scripts/08-05-clean-local-artifacts.sh --archive-pki "$ARCHIVE_ID"
unset ARCHIVE_ID
```

スクリプトは、対象が固定archive parent直下の権限`700`ディレクトリで、symbolic linkではなく、空stateを証明するcleanup markerを持ち、登録済みAccount IDと一致することを検証します。たとえばIDが`20260826-182800`なら、表示された移動元と移動先を確認して次を正確に入力します。

```text
ARCHIVE-PKI-INTO-20260826-182800
```

既存アーカイブにPKI保存先がある場合は上書きせず停止します。この操作でもSSH鍵、Pull Secret、expected Account ID、AWS CLI credentialは移動しません。

### 10.2 隔離済みアーカイブを後から永久削除する

保存期間終了後など、隔離した一式が不要になった場合だけ実行します。通常の`--delete`ではなく、アーカイブ専用モードを使用します。

```bash
read -r -p 'Archive ID in YYYYMMDD-HHMMSS format: ' ARCHIVE_ID
bash scripts/08-05-clean-local-artifacts.sh --delete-archive "$ARCHIVE_ID"
unset ARCHIVE_ID
```

同じarchive path、所有者、権限、cleanup marker、Account、region、workspace、managed resource件数を再検証します。たとえばIDが`20260826-182800`なら、表示された絶対パスを確認して次を正確に入力します。

```text
DELETE-LOCAL-LAB-ARCHIVE-20260826-182800
```

この操作は指定したアーカイブ全体だけを永久削除します。他のアーカイブと、アーカイブ外に保持したPKI、SSH鍵、Pull Secret、expected Account ID、AWS CLI credentialは対象外です。

いずれのモードでもSSH鍵、Pull Secret、expected Account ID、AWS CLI credentialは削除しません。Windows AWS VPN ClientのprofileとWindowsへコピーした`.ovpn`は手動で削除します。ラボ専用IAM access keyを廃止する場合はAWS側で無効化・削除してから、`~/.aws/credentials`のprofileを安全に処理します。

## 11. 完了条件

- `scripts/08-04-validate-cleanup.sh`が`Failures: 0`。
- Terraform stateにmanaged resourceがない。
- Client VPN用ACM証明書とローカルARNファイルがない。
- 既存Public Hosted Zoneと他用途リソースが保持されている。
- Windows AWS Client VPNが切断され、保持/削除するprofileとPKIを判断済み。
- Windowsへ登録したクラスター固有Ingress CAが、現在ユーザーの信頼ストアに残っていない。
- recovery markerが残っていない。
- クラスター固有資材を次回構築へ再利用しない。
- 配布する場合は[配布物作成手順](release-process.md)の監査を合格させ、state、Plan、provider cache、ログ、secret、kubeconfig、Ignitionを含まないクリーンなrelease archiveだけを使用する。
