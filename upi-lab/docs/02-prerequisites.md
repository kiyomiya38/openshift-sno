# 02. AWS・WSL事前準備

## この章の目的

AWSへ変更を加える前に、作業端末、認証、SSH鍵、Pull Secret、クォータ、既存DNSを確認します。

この章はWindows 11、WSL2、Ubuntu 24.04系、x86_64を基準にしています。WindowsへのWSL/AWS Client VPN導入権限と、Ubuntuで`sudo`できることが必要です。AWS CloudShell、Git Bash、OpenShift Node上では実行しません。

## 1. WSL Ubuntuを開く

実行場所: Windows TerminalのPowerShell

```powershell
wsl --status
wsl --list --verbose
```

WSL2またはUbuntuがない場合は、管理者PowerShellで導入し、Windowsの指示に従って再起動します。

```powershell
wsl --install -d Ubuntu-24.04
```

Ubuntuを開きます。

```powershell
wsl -d '<wsl --list --verboseで表示されたUbuntu名>'
```

以降は、特記がなければWSL Ubuntuで実行します。配布archiveを受け取った場合は同梱SHA-256を照合して展開します。Gitから取得する場合は、組織が指定する信頼済みURLとrelease/tagを使用します。作業中ディレクトリのコピーや、他人のTerraform state入りフォルダーを受け取りません。

```bash
# release archiveの例
sha256sum -c openshift-upi-lab-source.tar.gz.sha256
tar -xzf openshift-upi-lab-source.tar.gz
cd openshift-upi-lab

# または、信頼済みURLの指定releaseをcloneする例
# git clone --branch '<release-tag>' --depth 1 '<repository-url>' openshift-sno
# cd openshift-sno/upi-lab
```

現在の`upi-lab`を`LAB_ROOT`へ登録します。

```bash
export LAB_ROOT="$PWD"
uname -s
uname -m
test -x "$LAB_ROOT/scripts/00-preflight.sh"
```

期待値は `Linux` と `x86_64` です。

## 2. AWS CLIプロファイルを設定する

ラボ専用IAM principalの認証情報をAWSコンソールで準備します。現在の実装はAWS CLI profileに保存された長期access keyで検証しています。ルートユーザーのaccess keyは使用しません。access keyはチャット、Markdown、Git、シェル履歴へ貼り付けません。

作業責任者から、使用を承認された12桁のAWS Account IDを**AWSへのログインとは別の経路**で受け取ります。現在ログインしているAccount IDをそのまま期待値として採用すると、最初から誤ったアカウントへ接続している場合を検出できません。

実行場所: WSL Ubuntu

```bash
aws configure --profile openshift-lab
```

対話入力は次のとおりです。

```text
AWS Access Key ID: 対話入力
AWS Secret Access Key: 対話入力
Default region name: ap-northeast-3
Default output format: json
```

確認します。

```bash
aws sts get-caller-identity --profile openshift-lab
aws configure get region --profile openshift-lab
```

承認済み値を設定し、ログイン先と照合します。実際のIDを手順書へ書き込みません。

```bash
export EXPECTED_AWS_ACCOUNT_ID='<承認済みの12桁Account ID>'
CURRENT_AWS_ACCOUNT_ID="$(aws sts get-caller-identity \
  --profile openshift-lab --query Account --output text)"

test "$CURRENT_AWS_ACCOUNT_ID" = "$EXPECTED_AWS_ACCOUNT_ID"
test "$(aws configure get region --profile openshift-lab)" = 'ap-northeast-3'
```

いずれかが失敗した場合は中止し、profileを修正します。`EXPECTED_AWS_ACCOUNT_ID`は新しいWSLシェルで再設定します。Account IDとIAM ARNを公開ログへ掲載しません。

照合に成功した値を、リポジトリ外のaccount guardへ登録します。

```bash
cd "$LAB_ROOT"
bash scripts/00-register-expected-account.sh
```

表示されたAccount、profile、regionを再確認し、次の形式の確認文字列を入力します。`<Account ID>`は画面に表示された承認済み値です。

```text
REGISTER-<Account ID>
```

guardは`~/.config/openshift-upi-lab/expected-account-id`へ権限`600`で保存されます。以後のplanner、Apply、検証、destroyはこの値とAWS loginを照合します。AWS loginから期待値を自動生成しません。

### 必要なIAM権限

このラボには少なくとも次の操作が必要です。`AdministratorAccess`を教材の前提にはせず、組織の管理者がラボ専用リソース、リージョン、タグへ制限したpolicyを作成してください。明示的なdeny、SCP、permission boundaryも事前に確認します。

| サービス | 必要な操作の範囲 |
|---|---|
| STS / Service Quotas | identity確認、EC2 vCPU quotaの読み取り |
| EC2/VPC | VPC、Subnet、route、IGW、NAT/EIP、Security Group/rule、DHCP Options、Key Pair、EC2、EBS、Client VPNの作成・読み取り・更新・削除 |
| Elastic Load Balancing v2 | NLB、Listener、Target Group、Target登録、属性の作成・読み取り・削除 |
| ACM | Client VPN server証明書のimport、tag、読み取り、削除 |
| CloudWatch Logs | Client VPN用log group/streamの作成・読み取り・削除 |
| IAM | ラボ用Role/Instance Profileの作成・削除、SSM managed policyのattach/detach、対象Roleに限定した`iam:PassRole` |
| Route 53 | Hosted Zoneとrecord setの**読み取りのみ** |
| Resource Groups Tagging API | 削除後のタグ付きリソース読み取り |

IAM権限の不足をAWSコンソールでの手動作成によって回避しません。`AccessDenied`が出た場合は必要actionとresourceを管理者へ提示し、policyを修正して同じスクリプトから再開します。

## 3. Terraformを導入する

最初に共通パッケージを導入します。

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl unzip gnupg wget \
  jq git openssl openssh-client dnsutils pipx
```

AWS CLI v2が未導入の場合は、[AWS公式Linuxインストール手順](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)から検証済み`2.36.14`のx86_64版を導入します。公開鍵とsignatureを[公式の署名検証手順](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#install-linux-verify-signature)で検証してから実行します。

```bash
AWS_CLI_VERSION='2.36.14'
curl -o /tmp/awscliv2.zip \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip"
curl -o /tmp/awscliv2.zip.sig \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip.sig"
# 公式ページのAWS CLI signing keyをimportした後に検証する。
gpg --verify /tmp/awscliv2.zip.sig /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli-install
sudo /tmp/awscli-install/aws/install --update
aws --version
```

UbuntuのSnap版ではなく、HashiCorp公式APTリポジトリから導入します。

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates gnupg software-properties-common wget

wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null

gpg --no-default-keyring \
  --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg \
  --fingerprint

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
apt-cache madison terraform | grep '1.15.8'
sudo apt-get install -y 'terraform=1.15.8-1'
terraform version
```

表示したGPG fingerprintを[HashiCorp公式Linuxインストール案内](https://developer.hashicorp.com/terraform/install#linux)の公開鍵情報と別経路で照合してから、Terraformを使用します。

## 4. Ansibleを導入する

UbuntuのシステムPythonを直接変更せず、公式ドキュメントが案内する`pipx`で`ansible-core`を分離して導入します。

```bash
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
pipx install 'ansible-core==2.21.2'
ansible --version
```

`pipx ensurepath`後は、新しいWSLシェルを開けばPATH設定が有効になります。AnsibleをAPTとpipxの両方へ重複導入しません。教材で必要なCollectionは後続の`requirements.yml`から導入します。配布リリースではCollectionのバージョン固定を確認し、未固定の場合は同じ動作を保証できないため先へ進みません。

## 5. 必要ツールを確認する

`oc`と`openshift-install`は、[Red Hat Hybrid Cloud ConsoleのDownloads](https://console.redhat.com/openshift/downloads)からLinux x86_64版を取得します。既定・検証済みの正確な`4.21.26`の2つのarchiveと対応するSHA-256をダウンロードし、公開されたchecksumと照合してから、`~/.local/bin`などPATH上へ配置します。archiveを信頼せず、checksum検証を省略しません。

```bash
install -d -m 700 ~/.local/bin
# ダウンロードした正確なファイル名と公式SHA-256を使用する。
sha256sum openshift-client-linux*.tar.gz
sha256sum openshift-install-linux*.tar.gz
tar -xzf openshift-client-linux*.tar.gz -C ~/.local/bin oc kubectl
tar -xzf openshift-install-linux*.tar.gz -C ~/.local/bin openshift-install
chmod 755 ~/.local/bin/oc ~/.local/bin/kubectl ~/.local/bin/openshift-install
```

次の全コマンドを確認します。

```bash
aws --version
terraform version
ansible --version
oc version --client
openshift-install version
jq --version
git --version
openssl version
dig -v
ssh -V
```

OpenShiftツールは正確な`4.21.26`へ統一します。`EXPECTED_OPENSHIFT_VERSION`で別patchを明示する機能はありますが未検証扱いであり、クリーンなE2E再検証なしに配布手順として使用しません。Terraformは検証時`1.15.8`（構成上`>= 1.8, < 2.0`）、AWS CLIはv2、Ansibleは検証時`2.21.2`です。実際の全バージョンを作業記録へ残します。

## 6. SSH鍵を作成する

既存ファイルを上書きしない専用名を使用します。

```bash
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/openshift_upi_lab -C openshift-upi-lab
chmod 600 ~/.ssh/openshift_upi_lab
chmod 644 ~/.ssh/openshift_upi_lab.pub
```

秘密鍵をGitへ追加してはいけません。

```bash
test -f ~/.ssh/openshift_upi_lab
ssh-keygen -lf ~/.ssh/openshift_upi_lab.pub
```

## 7. Pull Secretをローカルへ保存する

Pull Secretは、Red Hatアカウントで次の公式ページへログインして取得します。

- [Red Hat Hybrid Cloud Console: Pull Secret](https://console.redhat.com/openshift/install/pull-secret)
- 直接ページを開けない場合: [OpenShift Downloads](https://console.redhat.com/openshift/downloads)を開き、`Tokens` → `Pull secret`へ進む

ページの`Download pull secret`または`Download`を選択します。Pull SecretはRed Hatユーザーごとに発行され、レジストリへ認証するための情報を含みます。画面共有、チャット、Git、手順書へ内容を貼り付けません。

ダウンロードしたファイルを、リポジトリ外のWSLホームへ保存します。Windowsのダウンロードフォルダーへ`pull-secret.txt`として保存された場合は、`<Windowsユーザー>`を自分のユーザー名へ置き換えます。

```bash
install -d -m 700 ~/.config/openshift
install -m 600 \
  '/mnt/c/Users/<Windowsユーザー>/Downloads/pull-secret.txt' \
  ~/.config/openshift/pull-secret.json
```

ダウンロードではなく`Copy pull secret`を選択した場合は、次のファイルをエディターで開き、内容を貼り付けて保存します。

```bash
install -d -m 700 ~/.config/openshift
umask 077
vi ~/.config/openshift/pull-secret.json
```

どちらの方法でも、JSON構文と権限を確認します。Pull Secretそのものは画面へ出力しません。

```bash
jq empty ~/.config/openshift/pull-secret.json
chmod 600 ~/.config/openshift/pull-secret.json
stat -c '%a %n' ~/.config/openshift/pull-secret.json
```

`jq empty`が無言で終了し、`stat`の先頭が`600`なら正常です。Windows側に残ったダウンロードファイルは、WSL側への保存と検証が終わった後、不要であればWindowsから削除します。

## 8. EC2クォータを確認する

Standard系On-Demand InstanceのvCPUクォータを確認します。

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region ap-northeast-3 \
  --profile openshift-lab \
  --query 'Quota.{Name:QuotaName,Value:Value}'
```

次に、対象インスタンスタイプが各AZで提供されることを確認します。

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=m6i.xlarge,m6i.large,t3.medium,t3.small \
  --region ap-northeast-3 \
  --profile openshift-lab \
  --query 'InstanceTypeOfferings[].{AZ:Location,Type:InstanceType}' \
  --output table
```

この固定プロファイルの推定最小値はStandard系On-Demand `42 vCPU`、一時的な再試行や運用余裕を含む推奨値は`48 vCPU`以上です。必要vCPUはTerraform Planでも最終確認します。クォータが42未満なら構築を開始せず、48以上へ引き上げを申請します。42以上48未満はpreflightで警告となるため、容量不足のリスクを受け入れず引き上げを完了してから進むことを推奨します。

## 9. Hosted Zoneを特定する

### この手順で行うこと

既存の`lab.k8study.com` Public Hosted Zoneが、現在使用しているAWSアカウントに存在することを**読み取りだけで確認**します。この配布版はHosted Zoneの新規作成や親ゾーンからのNS委任を自動化しません。ゾーンが存在しない場合は構築を停止し、DNS管理者が作成・委任・名前解決を完了してからこの検査へ戻ります。この手順では、DNSレコードの作成、Hosted Zoneの削除、Terraformへのimportは行いません。

Hosted Zoneは、ドメインのDNSレコードをまとめて管理する入れ物です。今回のOpenShift内部DNSは後でEC2上のBINDへ作成しますが、既存のPublic Hosted Zoneを誤って作り直したり削除したりしないため、先に実物を特定します。

実行場所: WSL Ubuntu

最初に、操作対象のAWSアカウントを確認します。

```bash
aws sts get-caller-identity --profile openshift-lab
```

表示された`Account`と`Arn`が、今回使用するAWSアカウントとIAMユーザーであることを確認します。違う場合は、以降のコマンドを実行せず、AWSプロファイルを修正します。

次にHosted Zoneを検索します。

```bash
aws route53 list-hosted-zones-by-name \
  --dns-name lab.k8study.com \
  --profile openshift-lab \
  --query 'HostedZones[?Name==`lab.k8study.com.`].{Id:Id,Name:Name,Private:Config.PrivateZone}' \
  --output table
```

正常例は次のような表です。IDは環境ごとに異なります。

```text
------------------------------------------------
|             ListHostedZonesByName            |
+----------------------+----------------+-------+
| Id                   | Name           |Private|
+----------------------+----------------+-------+
| /hostedzone/Z0123... | lab.k8study.com.| False |
+----------------------+----------------+-------+
```

次を確認します。

- `Name`が`lab.k8study.com.`である。末尾の`.`はDNSの完全修飾名を表す正常な表示。
- `Private`が`False`である。
- 該当するPublic Hosted Zoneが1個である。

レコードを読み取り、既存ゾーンであることを確認します。

```bash
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name lab.k8study.com \
  --profile openshift-lab \
  --query "HostedZones[?Name=='lab.k8study.com.' && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text)

printf 'Hosted Zone ID: %s\n' "$HOSTED_ZONE_ID"

aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --profile openshift-lab \
  --query 'ResourceRecordSets[].{Name:Name,Type:Type}' \
  --output table
```

この出力にはDNS名とレコード種別だけが表示され、レコード値は表示しません。少なくともHosted Zone作成時に自動生成される`NS`と`SOA`が存在することを確認します。

異常時の対応:

- `None`または空になる: プロファイル、AWSアカウント、ゾーン名を確認する。
- `Private=True`しかない: Public Hosted Zoneが別に存在しないかAWSコンソールで確認する。
- 同名のPublic Hosted Zoneが複数ある: 使用中のゾーンをNS委任と照合するまで先へ進まない。
- `AccessDenied`: IAMユーザーへRoute 53の読み取り権限を追加する。

このIDは確認用です。Terraformコードではゾーン名を使ったdata sourceで読み取り参照し、既存Hosted Zoneをラボの削除対象に含めません。

## 10. Client VPN証明書の扱いを確認する

### この手順で行うこと

ここでは証明書をまだ作りません。後続のClient VPN構築で秘密情報をどこへ保存するかを準備するだけです。

AWS Client VPNの相互証明書認証では、次を使用します。

- CA: サーバー証明書とクライアント証明書を発行する認証局。
- サーバー証明書: AWS Client VPN Endpointが自身を証明するために使用。
- クライアント証明書: このWindows PCからVPNへ接続するときに使用。
- 秘密鍵: 証明書と対になる機密情報。GitやTerraform stateへ保存しない。

実行場所: WSL Ubuntu

秘密情報を置く専用ディレクトリだけを作ります。

```bash
install -d -m 700 ~/.config/openshift-upi-lab
install -d -m 700 ~/.config/openshift-upi-lab/pki
stat -c '%a %n' ~/.config/openshift-upi-lab/pki
```

正常時は先頭に`700`と表示されます。

```text
700 /home/<user>/.config/openshift-upi-lab/pki
```

この段階では、次を行いません。

- CAや証明書の生成
- AWS Certificate Manager（ACM）への登録
- Client VPN Endpointの作成
- 証明書や秘密鍵のリポジトリへのコピー

これらはTerraformネットワーク実装後のClient VPN構築手順で行います。TerraformはACMへ登録済みの証明書ARNだけを参照し、秘密鍵をstateへ入れない設計にします。

## 11. 事前スナップショットを保存する

### この手順で行うこと

構築前のAWSアカウント、リージョン、クォータ、Hosted Zoneをテキストへ記録します。構築後・削除後の状態と比較するための検査記録です。

実行場所: WSL Ubuntu

`logs/`は`.gitignore`の対象であり、Gitへ登録されません。

```bash
cd "$LAB_ROOT"
mkdir -p "$LAB_ROOT/logs"
chmod 700 "$LAB_ROOT/logs"

SNAPSHOT_FILE="logs/preflight-$(date +%Y%m%d-%H%M%S).txt"

{
  echo '=== Timestamp ==='
  date -Iseconds
  echo '=== AWS identity ==='
  aws sts get-caller-identity --profile openshift-lab
  echo '=== AWS region ==='
  aws configure get region --profile openshift-lab
  echo '=== EC2 Standard On-Demand vCPU quota ==='
  aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-1216C47A \
    --region ap-northeast-3 \
    --profile openshift-lab \
    --query 'Quota.{Name:QuotaName,Value:Value}'
  echo '=== Hosted Zone summary ==='
  aws route53 list-hosted-zones-by-name \
    --dns-name lab.k8study.com \
    --profile openshift-lab \
    --query 'HostedZones[?Name==`lab.k8study.com.`].{Id:Id,Name:Name,Private:Config.PrivateZone}'
} >"$SNAPSHOT_FILE"

chmod 600 "$SNAPSHOT_FILE"
printf 'Saved: %s\n' "$SNAPSHOT_FILE"
```

保存結果を確認します。ファイルの中にアクセスキー、Pull Secret、秘密鍵が含まれていないことも確認します。

```bash
ls -l "$SNAPSHOT_FILE"
sed -n '1,120p' "$SNAPSHOT_FILE"
git check-ignore "$SNAPSHOT_FILE"
```

`git check-ignore`でファイル名が表示されれば、Gitの除外設定が有効です。AWSアカウントIDとIAM ARNは表示されるため、検査結果をチャットや公開場所へ貼る場合はマスクします。

## 次へ進む条件

- `aws sts get-caller-identity --profile openshift-lab` が成功する。
- 正確な`4.21.26`の`oc`と`openshift-install`が利用できる。
- 専用SSH鍵とPull Secretがリポジトリ外にある。
- EC2 vCPUクォータと対象AZのインスタンス提供状況を確認済み。
- `lab.k8study.com` Hosted Zone IDを特定済み。
- ログイン中のAccount IDが、別経路で承認済みの`EXPECTED_AWS_ACCOUNT_ID`と一致する。
- `LAB_ROOT`が現在の`upi-lab`ディレクトリを指す。

すべて満たしたら[03. 構築作業の全体フロー](03-build-runbook.md)へ進み、`scripts/00-preflight.sh`を実行します。
