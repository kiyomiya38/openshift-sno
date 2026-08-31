# 05. 基盤EC2と基盤サービス

## 作成するAWSリソース

- 公式RHEL 9.6 AMIを使用する基盤EC2 7台
- 専用EC2 Key Pair
- Systems Manager用IAM RoleとInstance Profile
- 管理、DNS/NTP、HAProxy、Proxy/Registry、NFS、Internal NLB用Security Group
- Installerだけに事前装着するIgnition Server用Security Group（OpenShiftノードの作成準備まで受信ルールなし）
- Cluster Subnet 3AZへ固定Private IPを持つInternal NLB
- TCP `6443`、`22623`、`80`、`443`のTarget GroupとListener

EC2にPublic IPv4を付与しません。SSHはAWS Client VPNから`ec2-user`で接続します。

RHEL AMIは配布リリースで検証したIDを`terraform.tfvars`へ固定しています。Planで期待するAMI ID、Red Hat Owner、名前、x86_64、`available`が検証されることを確認し、実行時に名前検索で別AMIへ置き換えません。

## 1. 前提を確認する

AWS Client VPNを接続したまま、WSL Ubuntuで実行します。

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
  bash scripts/04-05-validate-client-vpn.sh
  terraform -chdir=terraform output client_vpn_endpoint_id
  ssh-keygen -lf ~/.ssh/openshift_upi_lab.pub
else
  echo 'STOP: Chapter 05 prerequisite validation was not started.' >&2
fi
unset LAB_CONTEXT_READY
```

`PASS: WSL work context is ready.`が表示されない場合は、後続コマンドを実行せず02章の手順1へ戻ります。`Client VPN validation PASSED.`、Client VPN Endpoint ID、専用公開鍵のfingerprintが表示されることを確認します。

## 2. 基盤EC2のPlanを保存する

専用スクリプトは既存Client VPNを維持する変数を自動設定し、`fmt`、`validate`、Plan保存まで実行します。

```bash
bash scripts/05-01-plan-infrastructure.sh
```

ARNやアカウントIDの値そのものは画面へ表示しません。Planは`terraform/infrastructure.tfplan`へ保存されます。

次の場合は停止します。

- `to change`または`to destroy`が1件でもある。
- 既存VPC、Subnet、NAT Gateway、Client VPNへの変更がある。
- EC2にPublic IPv4を付ける設定がある。
- 選択AMIがRed Hat所有のRHEL 9.6ではない。
- 意図しないリソースがある。

## 3. 保存済みPlanを確認する

```bash
cd "$LAB_ROOT"
terraform -chdir=terraform show -no-color infrastructure.tfplan \
  > /tmp/infrastructure-plan.txt

terraform -chdir=terraform show -json infrastructure.tfplan |
  jq -r '.resource_changes[] |
    [.address, (.change.actions | join(","))] | @tsv'

terraform -chdir=terraform show -json infrastructure.tfplan |
  jq -r '[.resource_changes[].change.actions[]] |
    group_by(.) | map({action: .[0], count: length})'
```

すべての変更actionが`create`であることを確認します。`update`、`delete`があればApplyしません。

## 4. 確認済みPlanをApplyする

```bash
cd "$LAB_ROOT"
bash scripts/05-02-apply-infrastructure.sh
```

このスクリプトは、承認済みAccount ID、AWS login、`default` workspace、保存済みPlanが正確な56件の作成だけを含むことを再検査します。検査に合格した後、適用するときだけ次を正確に入力します。

```text
Type APPLY-INFRASTRUCTURE to continue: APPLY-INFRASTRUCTURE
```

Applyに成功すると、使用済みの`infrastructure.tfplan`は削除されます。検査が失敗した場合やPlan作成後にstate・Account・workspaceが変化した場合は、直接`terraform apply`せず、`scripts/05-01-plan-infrastructure.sh`からPlanを作り直します。

## 5. AWSリソースを検証する

```bash
cd "$LAB_ROOT"
bash scripts/05-03-validate-infrastructure.sh
```

正常時:

```text
Failures: 0
Infrastructure validation PASSED.
```

Ansible未実行のため、この時点でNLB Targetが`unhealthy`なのは正常です。HAProxyとOpenShiftバックエンドがまだ待受していないためです。

## 6. VPN経由でInstallerへSSHする

WindowsのAWS Client VPNが`Connected`であることを確認し、WSLから実行します。

同じPrivate IPでEC2を再作成した場合は、今回の基盤7台に限って前回のSSH host keyを削除します。

```bash
for ip in 10.80.40.10 10.80.40.11 10.80.50.11 10.80.40.21 10.80.50.21 10.80.40.31 10.80.40.41; do
  ssh-keygen -R "$ip"
done
```

EC2を再作成していない通常実行では削除しません。

```bash
ssh -i ~/.ssh/openshift_upi_lab ec2-user@10.80.40.10
```

初回だけhost key確認へ`yes`と入力します。接続後に確認します。

```bash
hostname
cat /etc/redhat-release
ip -4 address show
exit
```

最後の`exit`は、`[ec2-user@...]$`からリモートSSHを終了してWSLの`...$`へ戻るために**1回だけ**実行します。WSLのプロンプトへ戻った後にもう一度`exit`するとWSLシェル自体が終了し、`LAB_ROOT`などの環境変数が失われます。意図してWSLを開き直した場合は、この章の手順1から作業コンテキストを復元します。

## 基盤EC2の完了条件

- Planに変更・削除がない。
- 基盤EC2 7台が`running`で、固定Private IPが設計どおり。
- 全EC2にPublic IPv4がない。
- Internal NLBが`active`で4 Listenerが存在する。
- AWS Client VPN経由でInstallerへSSHできる。

条件を満たした後、同じ章の手順7へ進み、実装済みのAnsible RoleとInventoryで基盤サービスを構成します。

## 7. 基盤サービスで構成するもの

Ansibleは次を構成します。

- 全7台: FQDN hostname、共通診断ツール、firewalld
- `dns-ntp-0/1`: BIND権威・キャッシュDNS、chrony、AWS Time Sync Service
- `haproxy-0/1`: API `6443`、Machine Config `22623`、Ingress `80/443`、health `1936`
- `proxy-registry`: Squid `3128`、TLS・Basic認証付きOCI Registry `5000`
- `nfs-0`: `/srv/nfs/openshift`のNFS export

Registryはこの段階ではイメージ保存先だけを作成します。OpenShiftリリースとCatalogの同期、クラスターの信頼CA設定、完全disconnected化はこの配布版の対象外です。

## 8. AnsibleとCollectionを準備する

実行場所: WSL Ubuntu

```bash
(
  set -Eeuo pipefail
  : "${LAB_ROOT:?ERROR: LAB_ROOT is unset. Repeat chapter 05 section 1.}"
  cd "$LAB_ROOT/ansible"
  test -s requirements.yml
  ansible-galaxy collection install \
    -r requirements.yml \
    -p ~/.ansible/collections
)
```

Ansible本体は02章でpipxへ導入したものを使用し、APT版を重複導入しません。実行スクリプトがPATHと`ANSIBLE_CONFIG`を設定するため、Windowsマウント配下のworld-writable判定で設定ファイルが無視される問題を回避します。Collectionの導入結果とバージョンを作業記録へ残します。

passphrase付きSSH鍵をAnsibleから利用できるよう、現在のWSLシェルの`ssh-agent`へ専用鍵を登録します。すでに同じ鍵が登録済みならpassphraseを再入力しません。

```bash
if [[ -z ${SSH_AUTH_SOCK:-} ]] || ! ssh-add -l >/dev/null 2>&1; then
  eval "$(ssh-agent -s)"
fi

if ! ssh-add -T "$HOME/.ssh/openshift_upi_lab.pub" >/dev/null 2>&1; then
  ssh-add "$HOME/.ssh/openshift_upi_lab"
fi

ssh-add -T "$HOME/.ssh/openshift_upi_lab.pub"
echo 'PASS: The dedicated SSH key is available through ssh-agent.'
```

`Enter passphrase for ...`が表示された場合は、02章で設定したSSH鍵のpassphraseを入力します。秘密鍵のpassphraseと次のRegistryパスワードは別の値です。新しいWSLシェルでは`ssh-agent`も引き継がれないため、この手順を再実行します。

## 9. Registryパスワードを設定する

パスワードはファイルやGitへ保存せず、現在のWSLシェルだけに設定します。

```bash
{
  unset REGISTRY_PASSWORD REGISTRY_PASSWORD_CONFIRM

  while :; do
    read -r -s -p 'Registry password (16 characters or more): ' REGISTRY_PASSWORD
    echo
    read -r -s -p 'Enter the same Registry password again: ' REGISTRY_PASSWORD_CONFIRM
    echo

    if (( ${#REGISTRY_PASSWORD} < 16 )); then
      printf 'ERROR: The Registry password has %d characters; at least 16 are required.\n' \
        "${#REGISTRY_PASSWORD}" >&2
    elif [[ "$REGISTRY_PASSWORD" != "$REGISTRY_PASSWORD_CONFIRM" ]]; then
      echo 'ERROR: The two Registry password entries do not match.' >&2
    else
      export REGISTRY_PASSWORD
      break
    fi
  done

  unset REGISTRY_PASSWORD_CONFIRM
  bash -c 'printf "PASS: REGISTRY_PASSWORD is exported (%d characters).\\n" "${#REGISTRY_PASSWORD}"'
}
```

コード全体を一度に貼り付けても、brace groupを先に読み込んでから対話入力を開始するため、後続のコマンド行を誤ってパスワードとして取り込みません。最後に`PASS: REGISTRY_PASSWORD is exported (... characters).`が表示されることを確認します。パスワードそのものは表示しません。

この値はRegistryのBasic認証に使用します。Apply後の検証と将来のイメージ同期でも同じ値が必要です。安全なパスワードマネージャーへ別途保存してください。

新しいWSLシェルを開くと環境変数は失われます。基盤サービス構成を再開するたびに同じパスワードを、この手順へ再入力します。値そのものを表示しません。次のような無出力の`test`だけでは成功・失敗を目視できないため使用しません。

```text
test "${#REGISTRY_PASSWORD}" -ge 16
```

## 10. Ansible事前検査を実行する

WindowsのAWS Client VPNが`Connected`であることを確認してから実行します。

```bash
cd "$LAB_ROOT"
bash scripts/05-04-ansible-preflight.sh
```

この処理はInventory表示、Playbook構文検査、全7台へのAnsible pingだけを行い、サービス設定を変更しません。正常時は最後に次が表示されます。

```text
Ansible preflight PASSED. No remote configuration was changed.
```

1台でも`UNREACHABLE`または`FAILED`ならApplyへ進みません。

## 11. Ansibleを適用する

事前検査が成功した後だけ実行します。

```bash
bash scripts/05-05-apply-infrastructure-services.sh
```

次の確認文字列を正確に入力します。

```text
Type APPLY-ANSIBLE-SERVICES to continue: APPLY-ANSIBLE-SERVICES
```

実行中、Registryのコンテナーイメージ取得に時間がかかる場合があります。`failed=0`になるまで次へ進みません。

## 12. 基盤サービスを検証する

Applyと同じシェルで実行します。

```bash
bash scripts/05-06-validate-infrastructure-services.sh
```

検査内容:

- 必須systemd serviceが`running`かつ`enabled`
- BIND 2台がAPIのNLB IP 3個とControl PlaneのPTRを返す
- chronyが同期済み
- HAProxy 2台のhealth endpointがHTTP 200
- RegistryへTLS＋Basic認証で接続できる
- InstallerからNFSv4.1で一時マウントし、exportへの書込・読込・削除ができる

NFSはTCP `2049`だけを使用するNFSv4構成です。`showmount -e`はrpcbindやmountdの追加ポートを必要とするため、この検査では使用しません。一時マウントは検査終了時に解除され、`/etc/fstab`も変更しません。

正常時は最後に次が表示されます。

```text
Infrastructure services validation PASSED.
```

## 13. Client VPN DNSをBINDへ切り替える

初回のClient VPNは、VPC Resolver `10.80.0.2`をDNSとして配布します。BIND構築と基盤サービス検査が完了したこの時点で、DNSを`10.80.40.11`と`10.80.50.11`へ切り替えます。これはClient VPN Endpointのin-place更新です。Endpoint、Association、Route、Authorization Rule、VPNプロファイルは作り直しません。

### 13.1 DNS切り替えPlanを作成する

実行場所: WSL Ubuntu

```bash
cd "$LAB_ROOT"
bash scripts/05-07-plan-client-vpn-dns.sh
```

次の1件だけであることを確認します。`create`、`delete`、`replace`または他リソースの`update`があれば停止します。

```text
aws_ec2_client_vpn_endpoint.lab[0]    update
Plan: 0 to add, 1 to change, 0 to destroy.
Client VPN DNS plan validation PASSED.
```

### 13.2 保存Planをレビューする

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color client-vpn-dns.tfplan
```

Client VPN EndpointのDNS Serversだけが変更され、既存のNetwork、基盤EC2、NLB、Client VPN Association、Route、Authorization Ruleに変更がないことを確認します。

### 13.3 保存済みPlanをApplyする

Planレビューに合格した後だけ実行します。

```bash
bash scripts/05-08-apply-client-vpn-dns.sh
```

次の確認文字列を正確に入力します。

```text
APPLY-CLIENT-VPN-DNS
```

Applyすると現在のVPNセッションが切断される場合があります。完了後、WindowsのAWS VPN Clientで`openshift-upi-lab`をいったん切断し、再接続します。VPNプロファイルの再出力や再インポートは不要です。

### 13.4 AWS側のDNS設定を検証する

VPNを再接続してからWSLで実行します。

```bash
cd "$LAB_ROOT"
bash scripts/05-09-validate-client-vpn-dns.sh
```

次を確認します。

```text
PASS: Client VPN DNS servers are 10.80.40.11,10.80.50.11
Client VPN validation PASSED.
```

### 13.5 Windowsで名前解決を検証する

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

## この章の完了条件

- Ansible事前検査で全7台が`SUCCESS`。
- `site.yml`が`failed=0`で完了。
- DNS正引き・逆引き、NTP、HAProxy、Registry、NFSの検査がすべて成功。
- RegistryパスワードをGit外の安全な場所へ保存。
- Client VPNのDNSが`10.80.40.11`と`10.80.50.11`へ切り替わっている。
- Windowsから内部名と外部名の両方を解決できる。

全条件を満たしたら[06. OpenShift UPIインストール](06-openshift-install.md)へ進みます。
