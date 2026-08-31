# 06. OpenShift UPIインストール

この章では保存済みPlanだけをApplyします。通常の`terraform plan`や`terraform apply`を直接実行しません。

## 実装方式

このラボではAWS EC2をオンプレミス機器に見立て、`platform: none`のUPIとして構築します。

- Installer `10.80.40.10`の内部HTTPからIgnitionを配信する。
- 完全なIgnitionはリポジトリとTerraform stateへ保存しない。
- EC2 user dataには、配布URL、SHA-512、ノード固有FQDNだけを含む小さいIgnition wrapperを渡す。
- VPC DHCP Optionsで、初回起動時からBIND `10.80.40.11`、`10.80.50.11`とNTPを使わせる。
- Bootstrap 1台、Control Plane 3台、Worker 3台を同じノード起動段階で作成する。
- Bootstrap完了後は、HAProxyとDNSから切り離してからBootstrap EC2だけを削除する。
- CSRは内容を確認し、1件ずつ明示承認する。一括承認しない。

内部HTTPは暗号化されません。通信元Security Group、Apacheの送信元制限、SHA-512検証を組み合わせています。本番ではHTTPSと専用CAも検討します。

## 作業を始める前の確認

実行場所: AWS Client VPN接続済みWSL Ubuntu

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
  if [[ -z ${REGISTRY_PASSWORD:-} || ${#REGISTRY_PASSWORD} -lt 16 ]]; then
    unset REGISTRY_PASSWORD REGISTRY_PASSWORD_CONFIRM
    while :; do
      read -r -s -p 'Registry password configured in chapter 05: ' REGISTRY_PASSWORD
      echo
      read -r -s -p 'Enter the same Registry password again: ' REGISTRY_PASSWORD_CONFIRM
      echo

      if (( ${#REGISTRY_PASSWORD} < 16 )); then
        printf 'ERROR: The Registry password has %d characters; at least 16 are required.\n' \
          "${#REGISTRY_PASSWORD}" >&2
      elif [[ "$REGISTRY_PASSWORD" != "$REGISTRY_PASSWORD_CONFIRM" ]]; then
        echo 'ERROR: The two Registry password entries do not match.' >&2
      else
        break
      fi
    done
    unset REGISTRY_PASSWORD_CONFIRM
  fi

  export REGISTRY_PASSWORD
  bash -c 'printf "PASS: REGISTRY_PASSWORD is exported (%d characters).\\n" "${#REGISTRY_PASSWORD}"'
else
  echo 'STOP: Registry password input was not started.' >&2
fi
unset LAB_CONTEXT_READY
```

`PASS: WSL work context is ready.`が表示されない場合は、後続コマンドを実行せず02章の手順1へ戻ります。新しいWSLシェルでは`REGISTRY_PASSWORD`が失われます。05章でRegistryへ設定し、安全なパスワードマネージャーへ保存した**同じ値**を2回入力します。新しいパスワードへ変更しません。最後の合格表示は値を公開せず、子プロセスから参照できることと文字数だけを確認します。

```bash
cd "$LAB_ROOT"
```

```bash
bash scripts/05-06-validate-infrastructure-services.sh
```

`Infrastructure services validation PASSED.`を確認してから続けます。

```bash
bash scripts/05-09-validate-client-vpn-dns.sh
```

`Client VPN validation PASSED.`を確認してからDNSを直接検査します。

```bash
dig @10.80.40.11 api-int.ocp.lab.k8study.com A
dig @10.80.50.11 test.apps.ocp.lab.k8study.com A
```

両スクリプトが`PASSED`し、DNSがNLBの3アドレスを返すことが前提です。

## 1. install-configとRHCOS AMIを準備する

```bash
bash scripts/06-01-prepare-openshift-install.sh
```

このスクリプトは次を行います。

- Pull SecretとSSH公開鍵をローカルファイルから読み込む。
- 既定のOpenShift `4.21.26`用`install-config.yaml`をリポジトリ外へ生成する。
- Proxyを`http://10.80.40.31:3128`へ設定する。
- `compute.replicas: 0`、`controlPlane.replicas: 3`、`platform: none`を設定する。
- 使用中の`openshift-install`から対応RHCOS AMIを取得し、Owner、状態、アーキテクチャをAWSで検証する。
- 古いinstallディレクトリがあれば、削除せず日時付きディレクトリへ退避する。

保存場所:

```text
~/.local/share/openshift-upi-lab/install/install-config.yaml
~/.local/share/openshift-upi-lab/install-config.backup.yaml
~/.local/share/openshift-upi-lab/cluster.env
```

これらには秘密情報が含まれるため、Gitへ追加しません。この段階ではManifest、Ignition、EC2は作成されません。ここは安全に作業を中断できるチェックポイントです。

## 2. クラスタ前提リソースのPlanを作る

```bash
bash scripts/06-02-plan-cluster-prerequisites.sh
```

完全削除後に03章から順に作り直した通常構築の期待値:

```text
Plan: 13 to add, 0 to change, 0 to destroy.
Cluster prerequisite Plan validation PASSED.
```

作成対象は、Cluster用DHCP Options、Nodeと役割別Security Group、Ignition通信を許可するルールです。Installer専用のIgnition Server用Security Groupは05章で作成・装着済みです。

再開時に次が表示された場合、変更は不要で保存Planも削除済みです。手順2.1と手順3を省略し、手順4へ進みます。

```text
Cluster prerequisites are already converged; no Apply is required.
Next: bash scripts/06-04-generate-stage-ignition.sh
```

新規構築でこの期待値と異なる場合はApplyしません。以前の配布版からstateを継続する場合だけ、[移行ノート](upgrade-notes.md)を確認します。

次がPlanに含まれた場合はapplyしません。

- OpenShift EC2インスタンス
- 既存Control Planeや基盤EC2の削除・置換
- VPC、NAT Gateway、Client VPN、NLBの削除・置換
- Public Hosted Zoneの変更

### 2.1 保存Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color cluster-prerequisites.tfplan
```

`scripts/06-02-plan-cluster-prerequisites.sh`が表示した許可済みactionだけであることを人手で確認します。期待しない作成、更新、削除、置換がある場合は手順3へ進みません。Planファイルが存在しない場合も、直前に`already converged`が表示された再開経路を除き停止します。

## 3. クラスタ前提リソースをapplyする

レビューに合格した保存済みPlanをapplyします。

```bash
bash scripts/06-03-apply-cluster-prerequisites.sh
```

表示されたら、次をそのまま入力します。

```text
APPLY-CLUSTER-PREREQUISITES
```

成功後、使用済みPlanは削除されます。

`Cluster prerequisite application is complete.`を確認してから手順4へ進みます。Ignition生成スクリプトも、Installerへ専用Security Groupが実際に割り当てられていなければ停止します。

## 4. ManifestとIgnitionを生成・配信する

```bash
bash scripts/06-04-generate-stage-ignition.sh
```

このスクリプトは次を行います。

1. Manifestを生成する。
2. `mastersSchedulable: false`を検査する。
3. `bootstrap.ign`、`master.ign`、`worker.ign`を生成する。
4. 3ファイルのIgnition仕様バージョン一致とSHA-512を検査する。
5. AnsibleでInstallerのApacheへ配置する。
6. Apacheを`10.80.40.10:8080`だけで待ち受けさせる。
7. Directory Indexを無効化し、Cluster subnetからだけ取得可能にする。

生成済みIgnitionには短命な証明書が含まれます。このラボでは生成後12時間以内にノードを起動します。翌日へ持ち越す場合は再利用せず、この章を最初からやり直します。

## 5. 起動前検証を行う

```bash
bash scripts/06-05-validate-cluster-prerequisites.sh
```

合格条件:

- VPCにCluster用DHCP Optionsが関連付いている。
- DNSとNTPがBIND/chrony 2台を指している。
- 両BINDが`api-int`と`*.apps`を正しく返す。
- 3種類のIgnitionがInstallerの内部HTTPから取得できる。
- ローカルIgnitionのSHA-512が一致する。
- OpenShift EC2がまだ0台である。

`Cluster prerequisite validation PASSED.`を確認してから進みます。

## 6. 7台のOpenShiftノードをPlanする

```bash
bash scripts/06-06-plan-cluster-nodes.sh
```

期待値:

```text
7 to add, 0 to change, 0 to destroy
```

作成対象は次の7台だけです。

| ノード | Private IP | AZ | Ignition |
|---|---:|---|---|
| bootstrap | `10.80.10.30` | 3a | bootstrap |
| control-plane-0 | `10.80.10.10` | 3a | master |
| control-plane-1 | `10.80.20.10` | 3b | master |
| control-plane-2 | `10.80.30.10` | 3c | master |
| worker-0 | `10.80.10.20` | 3a | worker |
| worker-1 | `10.80.20.20` | 3b | worker |
| worker-2 | `10.80.30.20` | 3c | worker |

全台`m6i.xlarge`、暗号化gp3、Public IPv4なし、IMDSv2必須です。このapplyからEC2とEBSの追加課金が始まります。

### 6.1 保存Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color cluster-nodes.tfplan
```

作成対象が表に記載した7台だけで、既存のNetwork、Client VPN、基盤EC2、NLB、Cluster前提リソースに変更がないことを確認します。レビューに合格するまで手順7へ進みません。

## 7. 7台のOpenShiftノードを起動する

```bash
bash scripts/06-07-apply-cluster-nodes.sh
```

確認文字列:

```text
APPLY-OPENSHIFT-NODES
```

この時点からBootstrap完了まで、Ignitionを再生成せず、Installer、DNS、HAProxy、Proxy、NLBを停止しません。

## 8. EC2とDNSを検証する

```bash
bash scripts/06-08-validate-cluster-nodes.sh
```

固定IP、Public IPv4なし、RHCOS AMI、IMDSv2、全ノードのA/PTRを検証します。成功後はBootstrap完了を待ちます。

## 9. Bootstrap完了を待つ

```bash
bash scripts/06-09-wait-for-bootstrap.sh
```

ログは次へ保存されます。

```text
~/.local/share/openshift-upi-lab/install/bootstrap-complete.log
```

`Bootstrap completion PASSED.`が表示された場合だけ次へ進みます。失敗時にノードを即再作成せず、[09. トラブルシューティング](09-troubleshooting.md)に従って証拠を確認します。

## 10. HAProxyとDNSからBootstrapを切り離す

この工程と次のBootstrap削除は、途中で中断しない作業枠で続けます。

```bash
bash scripts/06-10-cutover-from-bootstrap.sh
```

Ansibleは次の順序で処理します。

1. HAProxy 2台からControl Plane 3台のAPI/MCSを直接検査する。
2. HAProxyを1台ずつreloadし、Bootstrap backendを除く。
3. 両HAProxy経由のAPI/MCSを再検査する。
4. BIND 2台からBootstrap A/PTRを除く。

Control Plane起動直後は`/readyz`が一時的にHTTP 500を返す場合があります。切り替え前と切り替え後のAPI/MCS検査は最大12回、5秒間隔で再試行し、継続して正常性を確認できない場合はHAProxyとDNSを変更せず停止します。
5. Bootstrapが設定とDNSに残っていないことを検査する。

通常の基盤Ansible再実行でもBootstrapを再登録しないよう、stageはリポジトリ外へ保存されます。

## 11. Bootstrap EC2だけを削除する

```bash
bash scripts/06-11-plan-bootstrap-removal.sh
```

期待値:

```text
0 to add, 0 to change, 1 to destroy
```

削除対象が`aws_instance.openshift["bootstrap"]`の1件だけであることをスクリプトが検査します。

### 11.1 保存Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color bootstrap-removal.tfplan
```

`bootstrap`の削除1件だけであり、Control Plane、Worker、基盤EC2や他のAWSリソースに変更がないことを確認します。レビューに合格した後だけ続けます。

### 11.2 保存PlanをApplyし、削除結果を検証する

```bash
bash scripts/06-12-apply-bootstrap-removal.sh
```

確認文字列:

```text
REMOVE-BOOTSTRAP
```

スクリプトがstateを再検査し、次が表示されることを確認してからCSRレビューへ進みます。

```text
Bootstrap removal PASSED. Six permanent OpenShift nodes remain.
```

## 12. CSRを個別確認・承認する

```bash
bash scripts/06-13-review-csrs.sh
```

スクリプトは接続先APIとCluster IDをローカルのInstaller metadataに照合した後、Signer、Requestor、Subject、SANを表示します。さらに、Node bootstrap用のClient CSRまたはServing CSRであり、設計表のFQDN、固定IP、用途に完全一致するものだけに承認入力欄を表示します。`NOT ELIGIBLE - do not approve:`が表示されたCSRには入力欄が出ません。手動の`oc adm certificate approve`で迂回せず、内容を調査します。

Client CSR承認後にServing CSRが現れるため、このスクリプトを複数回実行します。次を満たすまで繰り返します。

承認待ちの間に同じノードのClient CSRが再生成される場合があります。Signer、Requestor、Subjectが設計値と一致するものは、重複分も含めて個別に確認・承認します。Serving CSRはさらにDNS SANと固定IP SANを照合してから承認します。

1件でもCSRを承認した回は、NodeがすぐReadyに見えても手順13へ進みません。Client承認後にServing CSRが追加される可能性があるため、画面の案内どおり30～60秒待って同じスクリプトを再実行します。

- Control Plane 3台とWorker 3台のFQDN、固定Internal IP、roleが設計表と完全一致し、全台が`Ready`。
- Pending CSRと、承認済みだが証明書が未発行のCSRがない。
- 不明なRequestor、FQDN、IPのCSRを承認していない。

承認を行わなかった確認回で、次の表示が出た場合だけ手順13へ進みます。

```text
Registered nodes: 6/6
Ready nodes: 6/6
Pending CSRs: 0
Approved but not issued CSRs: 0
Unresolved CSRs: 0
CSR and node readiness gate PASSED.
Next: bash scripts/06-14-wait-for-install-complete.sh
```

`WAIT:`または`Do not run scripts/06-14-wait-for-install-complete.sh yet.`が表示された場合は手順13へ進みません。この待機は異常終了と区別できるよう終了コード`2`を返します。30～60秒待って手順12を再実行してください。したがって、`bash scripts/06-13-review-csrs.sh && bash scripts/06-14-wait-for-install-complete.sh`と連結しても、未収束時は手順13を開始しません。

## 13. インストール完了を待つ

手順12の最後に`CSR and node readiness gate PASSED.`と、次のコマンドが表示された直後だけ実行します。

```bash
bash scripts/06-14-wait-for-install-complete.sh
```

スクリプトはAPI URL、Cluster ID、Infrastructure IDをローカル資材に照合し、設計どおりのFQDN、固定Internal IP、roleを持つNodeが正確に6台、全6台がReady、未解決CSRが0件であることを再検査してから`install-complete`を待ちます。成功後はInstallerのIgnition HTTPサービスを停止し、公開中のクラスタ固有Ignitionを削除して、停止と削除を検証します。`install-complete.ok`はこの検証まで成功した場合だけ作成されます。ローカルのIgnitionとkubeconfigはリポジトリ外に保持されます。

## 14. 完成したクラスターを検証する

```bash
bash scripts/06-15-validate-openshift-cluster.sh
```

合格条件:

- 6 NodeがReady。
- ClusterVersionがAvailable。
- 全ClusterOperatorがAvailableで、Progressing/Degradedではない。
- Pending CSRがない。
- APIとConsole RouteへVPN経由で到達できる。
- NLBの4 Target GroupでHAProxy 2台がhealthy。
- Terraform stateに永久ノード6台だけが存在し、Bootstrapがない。

一時的にOperatorがProgressingの場合は、状態が収束してから再実行します。

`Failures: 0`と`OpenShift cluster validation PASSED.`を確認します。

### 14.1 `oc`でクラスターを直接確認する

```bash
export KUBECONFIG="$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig"

if [[ ! -r "$KUBECONFIG" ]]; then
  echo "ERROR: kubeconfig is not readable: $KUBECONFIG" >&2
else
  oc whoami
  oc whoami --show-server
  oc whoami --show-console
  oc get clusterversion version
  oc get nodes -o wide
  oc get clusteroperators
  oc get csr
fi
```

このコードはリポジトリ外に保存された、このクラスター専用のkubeconfigを現在のWSLシェルへ設定します。新しいWSLシェルでは再実行します。次を確認します。

- Identityが`system:admin`。
- API Serverが`https://api.ocp.lab.k8study.com:6443`。
- Console URLが`https://console-openshift-console.apps.ocp.lab.k8study.com`。
- ClusterVersionが`Available=True`。
- 設計表のControl Plane 3台とWorker 3台がすべて`Ready`。
- 全ClusterOperatorが`Available=True`、`Progressing=False`、`Degraded=False`。
- CSRの履歴に`Approved,Issued`が残っていても問題ありませんが、`Pending`は0件。

### 14.2 Console URLと初期認証情報の場所を確認する

```bash
CONSOLE_URL="$(oc whoami --show-console)"
CONSOLE_ROUTE_HOST="$(oc -n openshift-console get route console -o jsonpath='{.spec.host}')"
KUBEADMIN_PASSWORD_FILE="$HOME/.local/share/openshift-upi-lab/install/auth/kubeadmin-password"

if [[ "$CONSOLE_ROUTE_HOST" != 'console-openshift-console.apps.ocp.lab.k8study.com' ]]; then
  echo "ERROR: Unexpected Console Route host: $CONSOLE_ROUTE_HOST" >&2
elif [[ -z "$CONSOLE_URL" || "${CONSOLE_URL%/}" != "https://$CONSOLE_ROUTE_HOST" ]]; then
  echo "ERROR: Unexpected Console URL: $CONSOLE_URL" >&2
elif [[ ! -r "$KUBEADMIN_PASSWORD_FILE" ]]; then
  echo "ERROR: kubeadmin password file is not readable: $KUBEADMIN_PASSWORD_FILE" >&2
else
  printf 'Console URL: %s\n' "$CONSOLE_URL"
  printf 'Login user: kubeadmin\n'
  printf 'Password file: %s\n' "$KUBEADMIN_PASSWORD_FILE"
fi
```

この時点ではpassword自体を表示しません。`CONSOLE_URL`が設計値と異なる場合やpasswordファイルが読めない場合は、ブラウザーを開かず原因を確認します。

### 14.3 ラボのIngress CA公開証明書を取得・検証する

```bash
(
  set -Eeuo pipefail
  export KUBECONFIG="$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig"
  CONSOLE_URL="$(oc whoami --show-console)"
  CONSOLE_HOST="${CONSOLE_URL#https://}"
  CONSOLE_HOST="${CONSOLE_HOST%%/*}"
  INGRESS_CA_DIR="$HOME/.local/share/openshift-upi-lab/certificates"
  INGRESS_CA_FILE="$INGRESS_CA_DIR/ingress-ca.crt"

  [[ "$CONSOLE_HOST" == 'console-openshift-console.apps.ocp.lab.k8study.com' ]]
  mkdir -p "$INGRESS_CA_DIR"
  chmod 700 "$INGRESS_CA_DIR"
  umask 077
  TEMP_CA="$(mktemp "$INGRESS_CA_DIR/.ingress-ca.XXXXXX")"
  trap '[[ -z "${TEMP_CA:-}" ]] || rm -f -- "$TEMP_CA"' EXIT

  oc -n openshift-ingress-operator get secret router-ca \
    -o jsonpath='{.data.tls\.crt}' \
    | base64 --decode >"$TEMP_CA"

  openssl x509 -in "$TEMP_CA" -noout \
    -subject -issuer -dates -fingerprint -sha256 \
    -ext basicConstraints
  openssl x509 -in "$TEMP_CA" -noout -ext basicConstraints \
    | grep -Fq 'CA:TRUE'
  openssl verify -CAfile "$TEMP_CA" "$TEMP_CA"
  openssl s_client \
    -connect "${CONSOLE_HOST}:443" \
    -servername "$CONSOLE_HOST" \
    -CAfile "$TEMP_CA" \
    -verify_return_error </dev/null 2>&1 \
    | grep -F 'Verify return code: 0 (ok)'

  mv -- "$TEMP_CA" "$INGRESS_CA_FILE"
  TEMP_CA=''
  chmod 644 "$INGRESS_CA_FILE"
  printf 'Windows certificate path: %s\n' \
    "$(wslpath -w "$INGRESS_CA_FILE")"
)
```

`CA:TRUE`、自己署名証明書の`OK`、`Verify return code: 0 (ok)`、SHA-256 fingerprint、Windows certificate pathを確認します。取得するのは`router-ca` Secretの公開証明書`tls.crt`だけです。秘密鍵は取得しません。

このラボはIngress Operator生成の既定証明書を使用するため、Windowsが発行元CAをまだ信頼していない場合、ChromeやEdgeはOAuth Routeで証明書エラーになります。`thisisunsafe`や証明書検証を無効化する起動オプションでは回避しません。

### 14.4 Windowsの現在ユーザーでIngress CAを信頼する

次はWindows PowerShellでひとまとまりのコードとして実行します。

```powershell
$IngressCaPath = Read-Host 'Paste the Windows certificate path printed by WSL'

if (-not (Test-Path -LiteralPath $IngressCaPath -PathType Leaf)) {
  throw "Ingress CA certificate was not found: $IngressCaPath"
}

$IngressCa = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($IngressCaPath)

$IngressCa | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter

if ($IngressCa.Subject -ne $IngressCa.Issuer) {
  throw 'The selected certificate is not the self-signed lab Ingress CA.'
}

$Confirmation = Read-Host 'Type TRUST-OPENSHIFT-UPI-LAB-INGRESS-CA to continue'
$CertStorePath = "Cert:\CurrentUser\Root\$($IngressCa.Thumbprint)"

if ($Confirmation -ne 'TRUST-OPENSHIFT-UPI-LAB-INGRESS-CA') {
  Write-Output 'Certificate import cancelled.'
}

if ($Confirmation -eq 'TRUST-OPENSHIFT-UPI-LAB-INGRESS-CA') {
  if (Test-Path -LiteralPath $CertStorePath) {
    Write-Output 'The OpenShift UPI lab Ingress CA is already trusted.'
  }

  if (-not (Test-Path -LiteralPath $CertStorePath)) {
    Import-Certificate `
      -FilePath $IngressCaPath `
      -CertStoreLocation 'Cert:\CurrentUser\Root'
  }

  Get-Item -LiteralPath $CertStorePath |
    Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter
}
```

WSLが表示したWindows certificate pathを入力し、表示されたSubject、Issuer、Thumbprint、有効期限を確認してから、次を正確に入力します。

```text
TRUST-OPENSHIFT-UPI-LAB-INGRESS-CA
```

登録先はPC全体ではなく、現在のWindowsユーザーの`Trusted Root Certification Authorities`です。この証明書はクラスターごとに生成されるため、完全削除時は[08. 完全削除](08-destroy.md)の手順で同じThumbprintだけを削除します。

### 14.5 Windowsブラウザーからログインする

CA登録後、開いているChromeまたはEdgeのウィンドウをすべて終了します。AWS Client VPNの`openshift-upi-lab`へ再接続されていることを確認してから、Windows PowerShellで実行します。

```powershell
$ConsoleUrl = Read-Host 'Paste the Console URL printed by WSL'
$ConsoleUri = [Uri]$ConsoleUrl

if ($ConsoleUri.Scheme -ne 'https' -or
    $ConsoleUri.Host -ne 'console-openshift-console.apps.ocp.lab.k8study.com') {
  throw "Unexpected Console URL: $ConsoleUrl"
}

$ExpectedAddresses = @('10.80.10.5', '10.80.20.5', '10.80.30.5') | Sort-Object
$ResolvedAddresses = @(
  Resolve-DnsName $ConsoleUri.Host -Type A |
    Where-Object IPAddress |
    Select-Object -ExpandProperty IPAddress -Unique |
    Sort-Object
)
$DnsDifference = @(Compare-Object $ExpectedAddresses $ResolvedAddresses)

if ($DnsDifference.Count -ne 0) {
  throw "Console DNS does not match the three internal NLB addresses: $($ResolvedAddresses -join ',')"
}

if (-not (Test-NetConnection $ConsoleUri.Host -Port 443 -InformationLevel Quiet)) {
  throw 'TCP/443 to the OpenShift Console failed. Check AWS Client VPN connectivity.'
}

Start-Process $ConsoleUrl
```

ブラウザーにOAuthログイン画面が証明書警告なしで表示された後、同じWSLシェルで初期passwordを表示します。

```bash
cat "$HOME/.local/share/openshift-upi-lab/install/auth/kubeadmin-password"
```

この出力は秘密情報です。画面共有、チャット、Issue、Git、通常の作業ログ、ブラウザーのpassword保存へ残しません。ログイン画面へ次を入力します。

```text
Username: kubeadmin
Password: 上のコマンドで表示された文字列
```

ログイン後、`Home` → `Overview`でクラスター状態を確認し、`Compute` → `Nodes`でControl Plane 3台とWorker 3台がすべて`Ready`であることを確認します。

`kubeadmin`は初期構築用の強い管理権限を持ちます。クラスターを継続運用する場合はIdentity Providerと通常の管理者を構成し、別の`cluster-admin`でログインできることを確認してから`kubeadmin`の廃止を検討します。本番環境ではIngress Operator生成の既定証明書を利用者端末へ配布せず、組織CAまたはpublic CAが発行した`*.apps.ocp.lab.k8study.com`用の証明書へ置き換えます。

参照先:

- [OpenShift Container Platform 4.21: Accessing the web console](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/web_console/web-console)
- [OpenShift Container Platform 4.21: Ingress certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/observability/security_and_compliance/tls-security-profiles#ingress-certificates)

## 中断可能な位置

| 位置 | 中断 |
|---|---|
| `scripts/06-01-prepare-openshift-install.sh`完了後、Ignition生成前 | 可 |
| `scripts/06-04-generate-stage-ignition.sh`完了後、ノード起動前 | 同じ作業枠で続行を推奨。12時間を超えたら再生成 |
| ノード起動後からbootstrap-completeまで | 原則中断しない |
| HAProxy切り離しからBootstrap削除まで | 中断しない |
| Bootstrap削除後 | 可。ただしCSRは早めに確認 |
| install-complete後 | 可 |

## 失敗・翌日再開時の原則

- 新しいシェルでは`LAB_ROOT`と必要なsecret環境変数を再設定し、AWS profileの認証が有効であることを確認する。保存済みaccount guardは自動利用されるためAccount IDを再入力しない。
- 保存Planを作成した後にstate、workspace、AWS認証、Terraform定義を変更した場合、そのPlanをApplyせず同じplannerから作り直す。
- `scripts/06-04-generate-stage-ignition.sh`で作成したinstallディレクトリ、Ignition、`cluster.env`を別の構築へ流用しない。12時間を超えた場合は新しいinstall-configからこの章をやり直す。
- ノード起動後の失敗では、`bootstrap-complete.log`、EC2 console output、該当サービスログを保全する。原因を確認せずEC2を再作成しない。
- `scripts/06-10-cutover-from-bootstrap.sh`が失敗した場合は、成功するまで`scripts/06-11-plan-bootstrap-removal.sh`へ進まない。Bootstrap削除Planが既にある場合も、切り替え検証をやり直してからPlanを作り直す。
- Pending CSRは`scripts/06-13-review-csrs.sh`で設計表と照合し、一括承認しない。
- 構築を断念する場合は、手動削除せず[08. 完全削除](08-destroy.md)へ進む。

## 注意事項

- `platform: none`ではMachine API、AWS CCM、自動LoadBalancer作成などAWS統合機能を利用できません。
- `compute.replicas`はUPIのため`0`です。実際のWorker 3台はTerraformで手動作成します。
- Pull Secret、Ignition、kubeconfig、kubeadmin情報をチャット、Git、共有フォルダーへ貼り付けません。
- Control PlaneやWorkerの置換・削除を含むPlanはapplyしません。
- 毎日の完全削除後は、古いIgnitionやkubeconfigを次のクラスターへ再利用しません。

## 次へ

中断・再開時の原則と注意事項まで確認したら、[07. StorageClassと障害試験](07-storage-and-failure-tests.md)へ進みます。
