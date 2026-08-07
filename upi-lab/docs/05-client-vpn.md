# 05. AWS Client VPN

## この章の目的

Windows 11からPrivate Subnetだけで構成されたラボへ接続する管理経路を作ります。認証には、1台の管理PC用の相互証明書認証を使用します。

```text
Windows 11
    |
AWS Client VPN: 10.81.0.0/22
    |
Infra-a / Infra-b Subnet association
    |
VPC: 10.80.0.0/16
```

Split tunnelを有効にし、VPC宛て通信だけをVPNへ送ります。インターネット通信は通常のローカル回線を使用します。

この実装は`infra-a`と`infra-b`の2 AZへassociateし、VPC宛routeを両associationで検証します。これはClient VPN管理経路の可用性を高めますが、端末、証明書、インターネット回線、他の単一障害点を解消するものではありません。

## 作成するもの

リポジトリ外のローカルファイル:

- CA証明書と秘密鍵
- Server証明書と秘密鍵
- 管理クライアント用証明書と秘密鍵（既定client名は`workstation-01`）
- Client VPN設定ファイル

AWSリソース:

- ACM Server certificate 1個
- CloudWatch Logs log group/stream
- Client VPN用Security Group
- Client VPN Endpoint
- Infra-a/Infra-b Subnetとのtarget network association 2件
- VPC CIDRへのauthorization rule

ServerとClient証明書を同じCAで発行するため、Client証明書はACMへ登録しません。TerraformはACM証明書ARNだけを扱い、秘密鍵をstateへ保存しません。

## 1. 前提条件を確認する

実行場所: WSL Ubuntu

```bash
cd "$LAB_ROOT"
bash scripts/01-validate-network.sh
```

最後が次の表示であることを確認します。

```text
Failures: 0
Network validation PASSED.
```

## 2. Client VPN用PKIを生成する

> 再構築時に`~/.config/openshift-upi-lab/pki`を保持している場合、この手順は再実行しません。証明書検査後、手順3のACM登録へ進みます。

次のスクリプトはOpenVPN Easy-RSA `3.2.6`の[検証バージョン一覧](../configs/tested-versions.yaml)に記録したcommitを`~/.cache`へ取得し、checkout先が正確に一致することを検査してから、秘密情報を`~/.config/openshift-upi-lab/pki`へ生成します。既存ファイルがある場合は上書きせず停止します。client名は小文字英数字とhyphenを使い、既定の`workstation-01`または端末を識別できる非個人名を指定します。

このスクリプトは非対話利用のためCA、server、client秘密鍵を`nopass`で生成します。秘密鍵ファイルまたは秘密鍵を埋め込んだ`.ovpn`を取得した人は追加パスフレーズなしで利用できるため、利用者専用領域、Windows ACL、端末暗号化で保護します。紛失・共有時はClient VPNを停止し、証明書/CAを更新します。

```bash
export CLIENT_NAME='workstation-01'
bash scripts/02-generate-client-vpn-pki.sh
```

正常時はServerとClientの両方で`OK`と表示され、最後に次が表示されます。

```text
PKI generation completed. Private keys remain outside the repository.
```

証明書の用途と期限を確認します。秘密鍵の内容は表示しません。

```bash
PKI_DIR="$HOME/.config/openshift-upi-lab/pki"
CLIENT_NAME="$(<"$PKI_DIR/client-name")"
CLIENT_CERT_BASENAME="client-$CLIENT_NAME"

openssl x509 \
  -in "$PKI_DIR/server.crt" \
  -noout -subject -issuer -dates -ext subjectAltName

openssl x509 \
  -in "$PKI_DIR/${CLIENT_CERT_BASENAME}.crt" \
  -noout -subject -issuer -dates
```

秘密鍵の権限を確認します。

```bash
stat -c '%a %n' \
  "$PKI_DIR/server.key" \
  "$PKI_DIR/${CLIENT_CERT_BASENAME}.key"
```

両方とも`600`であることが合格条件です。

選択したclient名は`$PKI_DIR/client-name`へmode `600`で保存されます。設定出力スクリプトはこのファイルを読み、再構築時も同じ証明書を選択します。1台のPKIを複数の管理端末へコピーしません。端末ごとの証明書発行・失効を行う場合は、この単一client教材の範囲を超えるためPKI運用を別途設計します。

## 3. Server証明書をACMへ登録する

この操作でAWS Certificate Managerに証明書を1個作成します。Client証明書は登録しません。

```bash
bash scripts/03-import-client-vpn-certificate.sh
```

正常時はACM certificateの`Status`が`ISSUED`になり、ARNが次のローカルファイルへ保存されます。

```text
~/.config/openshift-upi-lab/pki/acm-server-certificate-arn.txt
```

ARNは秘密鍵ではありませんが、アカウントIDを含むため公開場所ではマスクします。

## 4. Client VPN Planを作成する

実行場所: WSL Ubuntu

```bash
cd "$LAB_ROOT"
bash scripts/03a-plan-client-vpn.sh
```

plannerは登録済みAccount、region、`default` workspace、ACM ARNを照合し、managed stateが検証済みNetwork 26件だけであることを確認します。その後`fmt`、`validate`とexact action allowlistを検査し、合格時だけ`terraform/client-vpn.tfplan`を保存します。

期待する7件:

1. CloudWatch Logs log group
2. CloudWatch Logs log stream
3. Client VPN Security Group
4. Client VPN Endpoint
5. `infra-a` target network association
6. `infra-b` target network association
7. VPC authorization rule

```text
Client VPN Plan validation PASSED.
Expected summary: 7 to add, 0 to change, 0 to destroy.
Two target-network associations will be created in separate availability zones.
```

## 5. Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color client-vpn.tfplan
```

次を確認します。

- 既存Network 26件に変更・削除がない。
- Client CIDRは`10.81.0.0/22`、初期DNSはVPC Resolver `10.80.0.2`。
- split tunnelが有効。
- `infra-a`と`infra-b`の異なるAZへassociateする。
- VPC `10.80.0.0/16`へのauthorizationと各associationのrouteが作成される。
- Connection logが有効。

## 6. 保存PlanをApplyする

Client VPN Endpointと2つのassociationは料金対象です。

```bash
cd "$LAB_ROOT"
bash scripts/03b-apply-client-vpn.sh
```

Applyスクリプトはexact 7-create allowlist、Account、ACM ARNを再検証します。次を正確に入力します。

```text
APPLY-CLIENT-VPN
```

Associationの完了には数分から十数分かかる場合があります。成功後、使用済みPlanは削除されます。

## 7. AWS実リソースを検証する

```bash
cd "$LAB_ROOT"
bash scripts/05-validate-client-vpn.sh
```

正常時:

```text
Failures: 0
Client VPN validation PASSED.
```

この検査はEndpoint、Client CIDR、Split tunnel、初期DNS、2 AZ association、authorization rule、各associationのVPC routeをAWS APIで確認します。

## 8. Client設定を出力する

```bash
bash scripts/04-export-client-vpn-config.sh
```

最後にWSLパスとWindowsパスが表示されます。スクリプトは、CA名に空白がある場合にAWSが出力する不正な`verify-x509-name`行もOpenVPN互換の形式へ自動補正します。生成された`.ovpn`にはClient秘密鍵が含まれるため、内容を表示・共有しません。

## 9. WindowsへAWS Client VPNを導入する

[AWS公式Client VPNダウンロードページ](https://aws.amazon.com/vpn/client-vpn-download/)から、Windows x64版の最新クライアントをダウンロードしてインストールします。

AWS Client VPNを起動し、次の操作を行います。

1. `File` → `Manage Profiles`を開く。
2. `Add Profile`を選ぶ。
3. 表示されたWindowsパスの`openshift-upi-lab.ovpn`を指定する。
4. Profile名を`openshift-upi-lab`にする。
5. `Add Profile`を選ぶ。
6. 作成したProfileを選択し、`Connect`を押す。

WSLホームのファイルを選択できない場合は、エクスプローラーのアドレス欄へスクリプトが表示したWindowsパスを入力します。設定ファイルをWindows側へコピーした場合は、他ユーザーから読めない場所に保存します。

## 10. Windowsで接続を確認する

実行場所: Windows PowerShell

```powershell
Get-NetIPConfiguration
route print 10.80.0.0
Resolve-DnsName amazonaws.com
```

確認項目:

- AWS Client VPNが`Connected`。
- `10.81.0.0/22`からクライアントIPが割り当てられている。
- `10.80.0.0/16`のrouteがVPNインターフェースへ向いている。
- Split tunnelのため、通常のインターネット接続も継続する。
- VPC Resolver経由の名前解決が成功する。

まだ接続先EC2を作っていないため、Private IPへのSSH確認は次章で行います。

### 「ポートは別のプロセスですでに使用されています」と表示される場合

AWS VPN Clientの接続時に次が表示される場合があります。

```text
VPNプロセスの開始に失敗しました。ポートは別のプロセスですでに使用されています。
```

この表示だけでは実際のポート競合とは断定できません。AWS VPN Clientは、OpenVPN設定が不正で子プロセスが管理ポートを開けなかった場合にも同じエラーを表示します。まず、手順8のスクリプトで`.ovpn`を再出力し、既存プロファイルを削除して再インポートしてください。

AWS VPN Clientのサービスログに次がある場合は、CA名の空白が引用されていないことが原因です。

```text
Options error: Unrecognized option or missing or extra parameter(s): verify-x509-name
```

上記がなく、実際にポート443が待受されている場合だけ、Windows PowerShellで所有プロセスを確認します。

Windows PowerShellで確認します。

```powershell
Get-NetTCPConnection -State Listen -LocalPort 443 |
  Select-Object LocalAddress,LocalPort,OwningProcess

Get-Process -Id (Get-NetTCPConnection -State Listen -LocalPort 443).OwningProcess |
  Select-Object Id,ProcessName,Path
```

`host-switch`とRancher Desktopのパスが表示された場合は、タスクトレイのRancher Desktopアイコンを右クリックして`Quit`または`終了`を選び、完全に終了します。OpenShift UPI構築ではRancher Desktopを使用しません。

終了後に再確認します。

```powershell
Get-Process -Name 'host-switch' -ErrorAction SilentlyContinue
Get-NetTCPConnection -State Listen -LocalPort 443 -ErrorAction SilentlyContinue
```

何も表示されなければAWS VPN Clientから再接続します。Rancher Desktop以外が表示された場合は、そのプロセスの用途を確認してから終了または設定変更を判断します。用途不明のプロセスを強制終了しません。

AWS VPN ClientのWindowsログは次にあります。

```text
C:\Users\<Windowsユーザー>\AppData\Roaming\AWSVPNClient\logs
C:\Program Files\Amazon\AWS VPN Client\WinServiceLogs\<Windowsユーザー>
```

## DNSの段階的な切り替え

初回のClient VPNは、VPC Resolver `10.80.0.2`をDNSとして配布します。これにより、BIND EC2がまだ存在しない段階でも、VPN接続中のWindowsで通常の名前解決ができます。

BIND構築と基盤サービス検査が完了した後、DNSを`10.80.40.11`と`10.80.50.11`へ切り替えます。これはClient VPN Endpointのin-place更新です。Endpoint、Association、Route、Authorization Rule、VPNプロファイルは作り直しません。

### 1. DNS切り替えPlanを作成する

実行場所: WSL Ubuntu

```bash
cd "$LAB_ROOT"
bash scripts/10a-plan-client-vpn-dns.sh
```

スクリプトは既存ネットワーク、Client VPN、基盤サービスを有効なままPlanし、次の1件だけでなければ失敗します。

```text
aws_ec2_client_vpn_endpoint.lab[0]    update
Plan: 0 to add, 1 to change, 0 to destroy.
Client VPN DNS plan validation PASSED.
```

`create`、`delete`、`replace`または他リソースの`update`があればApplyしません。

期待するPlan:

```text
aws_ec2_client_vpn_endpoint.lab[0]    update
Plan: 0 to add, 1 to change, 0 to destroy.
Client VPN DNS plan validation PASSED.
```

### 2. 保存済みPlanをApplyする

Planの実出力を確認した後だけ実行します。

```bash
bash scripts/10b-apply-client-vpn-dns.sh
```

次の確認文字列を正確に入力します。

```text
Type APPLY-CLIENT-VPN-DNS to continue: APPLY-CLIENT-VPN-DNS
```

Applyすると現在のVPNセッションが切断される場合があります。完了後、WindowsのAWS VPN Clientで`openshift-upi-lab`をいったん切断し、再接続します。VPNプロファイルの再出力や再インポートは不要です。

### 3. AWS側のDNS設定を検証する

VPNを再接続してからWSLで実行します。

```bash
cd "$LAB_ROOT"
bash scripts/10c-validate-client-vpn-dns.sh
```

次を確認します。

```text
PASS: Client VPN DNS servers are 10.80.40.11,10.80.50.11
Client VPN validation PASSED.
```

`Failures: 0`、`Client VPN validation PASSED.`を確認したら、WindowsでVPNを再接続し、実際の名前解決を確認します。

### 4. Windowsで名前解決を検証する

実行場所: 管理者権限のWindows PowerShell

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4 |
  Where-Object InterfaceAlias -Like 'AWS Client VPN*'

Resolve-DnsName api.ocp.lab.k8study.com -Type A
Resolve-DnsName api-int.ocp.lab.k8study.com -Type A
Resolve-DnsName test.apps.ocp.lab.k8study.com -Type A
Resolve-DnsName mirror-registry.ocp.lab.k8study.com -Type A
Resolve-DnsName registry.redhat.io -Type A
```

VPN AdapterのDNSがBIND 2台になり、APIと`*.apps`がNLBの`10.80.10.5`、`10.80.20.5`、`10.80.30.5`、Mirror Registryが`10.80.40.31`を返すことを確認します。外部名もBINDの再帰問い合わせで解決できることを確認します。

確認結果:

- VPN AdapterのDNSは`10.80.40.11`、`10.80.50.11`。
- BIND 2台はAPIのNLB IP 3個を返す。
- Windowsの既定リゾルバーでAPI、API-INT、`*.apps`を解決できる。
- Mirror Registryは`10.80.40.31`を返す。
- `registry.redhat.io`をBINDの再帰問い合わせで解決できる。

以上を確認した時点でClient VPN DNS切り替えを完了とします。

## 次へ進む条件

- PKIの生成と証明書検査が成功。
- Server証明書がACMで`ISSUED`。
- Terraform validateが成功。
- Client VPN Planが想定リソースだけを追加し、変更・削除がない。
- ApplyとAWS API検証が成功。
- Windows AWS Client VPNが`Connected`。
- VPC routeと通常のインターネット接続を両立できる。
- BIND完成後、Client VPNのDNSが`10.80.40.11`と`10.80.50.11`へ切り替わっている。
- Windowsから内部名と外部名の両方を解決できる。
