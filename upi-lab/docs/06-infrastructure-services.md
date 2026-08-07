# 06. 基盤EC2と基盤サービス

## 作成するAWSリソース

- 公式RHEL 9.6 AMIを使用する基盤EC2 7台
- 専用EC2 Key Pair
- Systems Manager用IAM RoleとInstance Profile
- 管理、DNS/NTP、HAProxy、Proxy/Registry、NFS、Internal NLB用Security Group
- Installerだけに事前装着するIgnition Server用Security Group（Phase 6まで受信ルールなし）
- Cluster Subnet 3AZへ固定Private IPを持つInternal NLB
- TCP `6443`、`22623`、`80`、`443`のTarget GroupとListener

EC2にPublic IPv4を付与しません。SSHはAWS Client VPNから`ec2-user`で接続します。

RHEL AMIは配布リリースで検証したIDを`terraform.tfvars`へ固定しています。Planで期待するAMI ID、Red Hat Owner、名前、x86_64、`available`が検証されることを確認し、実行時に名前検索で別AMIへ置き換えません。

## 1. 前提を確認する

AWS Client VPNを接続したまま、WSL Ubuntuで実行します。

```bash
cd "$LAB_ROOT"
terraform -chdir=terraform output client_vpn_endpoint_id
ssh-keygen -lf ~/.ssh/openshift_upi_lab.pub
```

Client VPN Endpoint IDと専用公開鍵のfingerprintが表示されることを確認します。

## 2. Phase 4 Planを保存する

専用スクリプトは既存Client VPNを維持する変数を自動設定し、`fmt`、`validate`、Plan保存まで実行します。

```bash
bash scripts/07-plan-infrastructure.sh
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
bash scripts/07b-apply-infrastructure.sh
```

このスクリプトは、承認済みAccount ID、AWS login、`default` workspace、保存済みPlanが正確な56件の作成だけを含むことを再検査します。検査に合格した後、適用するときだけ次を正確に入力します。

```text
Type APPLY-INFRASTRUCTURE to continue: APPLY-INFRASTRUCTURE
```

Applyに成功すると、使用済みの`infrastructure.tfplan`は削除されます。検査が失敗した場合やPlan作成後にstate・Account・workspaceが変化した場合は、直接`terraform apply`せず、`scripts/07-plan-infrastructure.sh`からPlanを作り直します。

## 5. AWSリソースを検証する

```bash
cd "$LAB_ROOT"
bash scripts/06-validate-infrastructure.sh
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

## 次へ進む条件

- Planに変更・削除がない。
- 基盤EC2 7台が`running`で、固定Private IPが設計どおり。
- 全EC2にPublic IPv4がない。
- Internal NLBが`active`で4 Listenerが存在する。
- AWS Client VPN経由でInstallerへSSHできる。

条件を満たした後、実装済みのAnsible RoleとInventoryを使ってPhase 5へ進みます。

## 7. Phase 5で構成するサービス

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
cd "$LAB_ROOT/ansible"
ansible-galaxy collection install \
  -r requirements.yml \
  -p ~/.ansible/collections
```

Ansible本体は[02. 事前準備](02-prerequisites.md#4-ansibleを導入する)でpipxへ導入したものを使用し、APT版を重複導入しません。実行スクリプトがPATHと`ANSIBLE_CONFIG`を設定するため、Windowsマウント配下のworld-writable判定で設定ファイルが無視される問題を回避します。Collectionの導入結果とバージョンを作業記録へ残します。

## 9. Registryパスワードを設定する

パスワードはファイルやGitへ保存せず、現在のWSLシェルだけに設定します。

```bash
read -r -s -p 'Registry password (16 characters or more): ' REGISTRY_PASSWORD
echo
export REGISTRY_PASSWORD
```

この値はRegistryのBasic認証に使用します。Apply後の検証と将来のイメージ同期でも同じ値が必要です。安全なパスワードマネージャーへ別途保存してください。

新しいWSLシェルを開くと環境変数は失われます。Phase 5を再開するたびに同じパスワードを再入力し、次で長さだけを確認します。値そのものを表示しません。

```bash
test "${#REGISTRY_PASSWORD}" -ge 16
```

## 10. Ansible事前検査を実行する

WindowsのAWS Client VPNが`Connected`であることを確認してから実行します。

```bash
cd "$LAB_ROOT"
bash scripts/08-ansible-preflight.sh
```

この処理はInventory表示、Playbook構文検査、全7台へのAnsible pingだけを行い、サービス設定を変更しません。正常時は最後に次が表示されます。

```text
Ansible preflight PASSED. No remote configuration was changed.
```

1台でも`UNREACHABLE`または`FAILED`ならApplyへ進みません。

## 11. Ansibleを適用する

事前検査が成功した後だけ実行します。

```bash
bash scripts/09-apply-infrastructure-services.sh
```

次の確認文字列を正確に入力します。

```text
Type APPLY-ANSIBLE-SERVICES to continue: APPLY-ANSIBLE-SERVICES
```

実行中、Registryのコンテナーイメージ取得に時間がかかる場合があります。`failed=0`になるまで次へ進みません。

## 12. 基盤サービスを検証する

Applyと同じシェルで実行します。

```bash
bash scripts/10-validate-infrastructure-services.sh
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

## Phase 5の次へ進む条件

- Ansible事前検査で全7台が`SUCCESS`。
- `site.yml`が`failed=0`で完了。
- DNS正引き・逆引き、NTP、HAProxy、Registry、NFSの検査がすべて成功。
- RegistryパスワードをGit外の安全な場所へ保存。
- BIND完成後のClient VPN DNS切り替えPlanを別途確認。

全条件を満たし、[05. AWS Client VPN](05-client-vpn.md#dnsの段階的な切り替え)でDNS切り替えまで検証した後、[07. OpenShift UPIインストール](07-openshift-install.md)のスクリプト15からPhase 6を開始します。
