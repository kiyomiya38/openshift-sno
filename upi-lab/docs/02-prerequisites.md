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
$UbuntuName = Read-Host 'Ubuntu name shown by wsl --list --verbose'
if ([string]::IsNullOrWhiteSpace($UbuntuName)) {
  throw 'Ubuntu name must not be empty.'
}
wsl -d $UbuntuName
```

入力待ちでは、直前の一覧に表示された名前を入力します。この環境の表示が`Ubuntu`なら`Ubuntu`と入力します。`<...>`のようなプレースホルダーをコマンドとして入力しません。

以降は、特記がなければWSL Ubuntuで実行します。

この文書をローカルの`openshift-sno/upi-lab/docs`から開いている時点で、リポジトリの取得は完了しています。**archiveの展開や`git clone`を実行しません。** 配布archiveをまだ展開していない利用者は、この文書を開始する前に、配布元から別途提示された取得手順でSHA-256照合と展開を完了してください。プレースホルダーのURLやrelease tagを推測して実行しません。作業中ディレクトリのコピーや、他人のTerraform state入りフォルダーも使用しません。

現在の`upi-lab`を`LAB_ROOT`へ登録します。次のコード全体を貼り付けます。現在位置がリポジトリ直下の`openshift-sno`でも、`upi-lab`へ自動では移動しないため、入力待ちで`upi-lab`まで含む絶対パスを指定します。

```bash
unset LAB_ROOT
LAB_ROOT_FILE="$HOME/.config/openshift-upi-lab/lab-root"
read -r -e -p 'UPI lab path in WSL: ' UPI_LAB_PATH

if [[ ! -d "$UPI_LAB_PATH" ]]; then
  echo "ERROR: Directory not found: $UPI_LAB_PATH" >&2
elif [[ ! -f "$UPI_LAB_PATH/README.md" || \
        ! -d "$UPI_LAB_PATH/docs" || \
        ! -d "$UPI_LAB_PATH/terraform" || \
        ! -x "$UPI_LAB_PATH/scripts/02-03-preflight.sh" ]]; then
  echo "ERROR: Not the OpenShift UPI lab root: $UPI_LAB_PATH" >&2
else
  cd "$UPI_LAB_PATH"
  export LAB_ROOT="$PWD"
  install -d -m 700 "$(dirname "$LAB_ROOT_FILE")"
  printf '%s\n' "$LAB_ROOT" > "$LAB_ROOT_FILE"
  chmod 600 "$LAB_ROOT_FILE"
  printf 'LAB_ROOT=%s\n' "$LAB_ROOT"
  printf 'Saved path=%s\n' "$LAB_ROOT_FILE"
  uname -s
  uname -m
  echo 'PASS: OpenShift UPI lab root was set.'
fi

unset LAB_ROOT_FILE UPI_LAB_PATH
```

コードを貼り付けると`UPI lab path in WSL:`で入力待ちになります。本書の構築例では、次のように入力します。

```text
UPI lab path in WSL: /mnt/c/Users/<Windowsユーザー>/openshift-sno/upi-lab
```

`<Windowsユーザー>`を使用しているWindowsアカウント名へ置き換えます。正常時は`LAB_ROOT`の末尾が`/upi-lab`となり、`Linux`、`x86_64`、`PASS: OpenShift UPI lab root was set.`が表示されます。`ERROR`が表示された場合や、`LAB_ROOT`の末尾が`/openshift-sno`だけの場合は先へ進みません。

`LAB_ROOT`環境変数はWSLシェルを閉じると失われます。そのため、検証済みパスを`~/.config/openshift-upi-lab/lab-root`へ権限`600`で保存します。03章以降は各章の最初にこの値を読み戻します。リポジトリを移動した場合は、この手順を再実行して保存先を更新します。

## 2. AWS CLI v2を確認し、プロファイルを設定する

最初に共通パッケージを導入します。すでに導入済みのパッケージは更新対象にならないため、重複してインストールされません。

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl unzip gnupg wget \
  jq git openssl openssh-client dnsutils pipx
```

AWS CLIの導入状態を確認します。

```bash
if command -v aws >/dev/null 2>&1; then
  aws --version
else
  echo 'ERROR: AWS CLI v2 is not installed.' >&2
fi
```

`aws-cli/2.`から始まるバージョンが表示された場合、AWS CLI v2は導入済みです。次の「AWS CLI v2が未導入の場合」へ進まず、ラボ専用IAM principalの設定へ進みます。

### AWS CLI v2が未導入の場合

前の確認で`ERROR: AWS CLI v2 is not installed.`が表示された場合だけ、この章をいったん停止します。[AWS公式Linuxインストール手順](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)と[公式の署名検証手順](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#install-linux-verify-signature)に従い、公開鍵、signature、archiveを検証してAWS CLI v2を導入します。署名鍵を省略した未検証archiveは実行しません。

導入後、この章の「AWS CLIの導入状態を確認します」へ戻り、`aws-cli/2.`から始まることを確認します。AWS CLI v1が表示された場合は使用しません。

### ラボ用プロファイルを設定する

ラボ専用IAM principalの認証情報をAWSコンソールで準備します。現在の実装はAWS CLI profileに保存された長期access keyで検証しています。ルートユーザーのaccess keyは使用しません。access keyはチャット、Markdown、Git、シェル履歴へ貼り付けません。

作業責任者から、使用を承認された12桁のAWS Account IDを**AWSへのログインとは別の経路**で受け取ります。現在ログインしているAccount IDをそのまま期待値として採用すると、最初から誤ったアカウントへ接続している場合を検出できません。

実行場所: WSL Ubuntu。既存profileが正しい場合は再設定せず再利用し、未設定・認証失敗・region不一致の場合だけ`aws configure`を開始します。

```bash
if aws sts get-caller-identity \
     --profile openshift-lab >/dev/null 2>&1 && \
   [[ "$(aws configure get region --profile openshift-lab)" == 'ap-northeast-3' ]]; then
  echo 'PASS: Existing openshift-lab profile was retained.'
else
  echo 'The openshift-lab profile must be configured.'
  aws configure --profile openshift-lab
fi
```

`aws configure`が開始された場合だけ、次を対話入力します。`PASS: Existing openshift-lab profile was retained.`と表示された場合は入力しません。

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

承認済み値をログイン先と照合し、account guardへ登録します。登録スクリプトが必要な入力と検査を行うため、環境変数の手動設定や長い条件分岐は不要です。入力する値は現在のAWS sessionから初めて知った値ではなく、作業責任者が事前承認したAccount IDです。

```bash
cd "$LAB_ROOT"
bash scripts/02-01-register-expected-account.sh
```

`Approved 12-digit AWS Account ID (not an AKIA/ASIA access key):`で入力待ちになったら、承認済みの12桁だけを入力してEnterを押します。`123456789012`のような12桁がAccount IDです。`AKIA`または`ASIA`から始まる英数字はAccess Key IDなので入力しません。Secret Access Keyも絶対に入力しません。

スクリプトはAccount IDの形式、`openshift-lab`のログイン先、`ap-northeast-3`を検査します。いずれかが異なる場合はguardを保存しません。Account ID、IAM ARN、Access Key IDを配布ログへ掲載しません。

表示されたAccount、profile、regionを再確認し、次の形式の確認文字列を入力します。`<Account ID>`は画面に表示された承認済み値です。

```text
REGISTER-<Account ID>
```

guardは`~/.config/openshift-upi-lab/expected-account-id`へ権限`600`で保存されます。以後のplanner、Apply、検証、destroyはこの値とAWS loginを自動照合します。新しいWSLシェルでもAccount IDの再入力や`EXPECTED_AWS_ACCOUNT_ID`のexportは不要です。AWS loginから期待値を自動生成しません。

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

まず検証済み版が既にあるか確認します。正確な`1.15.8`が見つかれば再導入しません。見つからない場合だけ、UbuntuのSnap版ではなくHashiCorp公式APTリポジトリから導入します。

```bash
TERRAFORM_REQUIRED_VERSION='1.15.8'
TERRAFORM_CURRENT_VERSION="$({ terraform version -json 2>/dev/null || true; } \
  | jq -r '.terraform_version // empty')"

if [[ "$TERRAFORM_CURRENT_VERSION" == "$TERRAFORM_REQUIRED_VERSION" ]]; then
  printf 'PASS: Terraform %s was retained.\n' "$TERRAFORM_CURRENT_VERSION"
else
  (
    set -Eeuo pipefail
    sudo apt-get update
    sudo apt-get install -y ca-certificates gnupg software-properties-common wget

    wget -O- https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor \
      | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null

    gpg --no-default-keyring \
      --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg \
      --fingerprint

    echo 'Compare the displayed fingerprint with the HashiCorp official page.'
    read -r -p 'Type HASHICORP-KEY-VERIFIED to continue: ' CONFIRM
    [[ "$CONFIRM" == 'HASHICORP-KEY-VERIFIED' ]] || {
      echo 'Terraform installation cancelled.' >&2
      exit 1
    }

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list

    sudo apt-get update
    apt-cache madison terraform | grep '1.15.8'
    sudo apt-get install -y 'terraform=1.15.8-1'
  )
fi

terraform version
unset TERRAFORM_REQUIRED_VERSION TERRAFORM_CURRENT_VERSION
```

表示したGPG fingerprintを[HashiCorp公式Linuxインストール案内](https://developer.hashicorp.com/terraform/install#linux)の公開鍵情報と別経路で照合してから、Terraformを使用します。

## 4. Ansibleを導入する

UbuntuのシステムPythonを直接変更せず、公式ドキュメントが案内する`pipx`で`ansible-core`を分離して導入します。正確な`2.21.2`が既に利用できる場合は再導入しません。

```bash
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"

ANSIBLE_REQUIRED_VERSION='2.21.2'
ANSIBLE_CURRENT_VERSION="$({ ansible --version 2>/dev/null || true; } \
  | sed -n '1s/.*core \([^]]*\).*/\1/p')"

if [[ "$ANSIBLE_CURRENT_VERSION" == "$ANSIBLE_REQUIRED_VERSION" ]]; then
  printf 'PASS: ansible-core %s was retained.\n' "$ANSIBLE_CURRENT_VERSION"
else
  pipx install --force "ansible-core==$ANSIBLE_REQUIRED_VERSION"
fi

ansible --version
unset ANSIBLE_REQUIRED_VERSION ANSIBLE_CURRENT_VERSION
```

`pipx ensurepath`後は、新しいWSLシェルを開けばPATH設定が有効になります。AnsibleをAPTとpipxの両方へ重複導入しません。教材で必要なCollectionは後続の`requirements.yml`から導入します。配布リリースではCollectionのバージョン固定を確認し、未固定の場合は同じ動作を保証できないため先へ進みません。

## 5. OpenShiftツールを確認・導入する

最初に、現在PATH上で選択される`oc`と`openshift-install`の場所とバージョンを確認します。

```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r

command -v oc || true
command -v openshift-install || true
oc version --client 2>/dev/null || true
openshift-install version 2>/dev/null || true
```

両方が正確に`4.21.26`の場合は再導入せず、次の「全コマンドを確認する」へ進みます。コマンドが見つからない場合や、片方でも別バージョンの場合だけ次を実行します。

```bash
cd "$LAB_ROOT"
bash scripts/02-02-install-openshift-tools.sh

export PATH="$HOME/.local/bin:$PATH"
hash -r
command -v oc
command -v openshift-install
oc version --client
openshift-install version
```

スクリプトは検証済み`4.21.26`のLinux x86_64版を[Red Hat公式mirror](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.26/)から一時ディレクトリへ取得します。公式`sha256sum.txt`によりクライアントとインストーラーの両方を検証した後、`~/.local/bin`へ配置します。ダウンロードファイルをカレントディレクトリへ事前配置する必要はありません。既に正確な版がPATH上にある場合、ダウンロードや上書きを行いません。

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

専用名を使用し、既存の正常な鍵ペアは再利用します。秘密鍵または公開鍵の片方だけがある場合は、上書きや再生成をせず停止します。

```bash
(
  set -Eeuo pipefail
  SSH_KEY="$HOME/.ssh/openshift_upi_lab"

  install -d -m 700 "$HOME/.ssh"

  if [[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]]; then
    echo 'Existing dedicated SSH key pair was retained.'
  elif [[ -e "$SSH_KEY" || -e "$SSH_KEY.pub" ]]; then
    echo 'ERROR: The SSH private/public key pair is incomplete.' >&2
    exit 1
  else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C openshift-upi-lab
  fi

  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_KEY.pub"
  ssh-keygen -lf "$SSH_KEY.pub"
)
```

新規生成時はpassphraseと確認入力を求められます。この構築例では空にせず、パスワードマネージャーで管理する専用passphraseを設定します。既存ペアを保持した場合はpassphraseを再入力しません。秘密鍵をGitへ追加してはいけません。

## 7. Pull Secretをローカルへ保存する

Pull Secretは、Red Hatアカウントで次の公式ページへログインして取得します。

- [Red Hat Hybrid Cloud Console: Pull Secret](https://console.redhat.com/openshift/install/pull-secret)
- 直接ページを開けない場合: [OpenShift Downloads](https://console.redhat.com/openshift/downloads)を開き、`Tokens` → `Pull secret`へ進む

ページの`Download pull secret`または`Download`を選択します。Pull SecretはRed Hatユーザーごとに発行され、レジストリへ認証するための情報を含みます。画面共有、チャット、Git、手順書へ内容を貼り付けません。

既存の有効なPull Secretは再利用します。存在しない場合だけ、ダウンロード済みファイルのコピーまたはエディターへの貼り付けのどちらか1つを選びます。Pull Secretそのものは画面へ出力しません。

```bash
(
  set -Eeuo pipefail
  PULL_SECRET="$HOME/.config/openshift/pull-secret.json"
  install -d -m 700 "$HOME/.config/openshift"

  if [[ -s "$PULL_SECRET" ]] && jq empty "$PULL_SECRET" 2>/dev/null; then
    echo 'Existing valid Pull Secret was retained.'
  elif [[ -e "$PULL_SECRET" ]]; then
    echo "ERROR: Existing Pull Secret is empty or invalid: $PULL_SECRET" >&2
    echo 'Repair or remove it explicitly, then rerun this step.' >&2
    exit 1
  else
    echo '1: Copy a downloaded Pull Secret file'
    echo '2: Paste the Pull Secret into vi'
    read -r -p 'Select one method [1/2]: ' PULL_SECRET_METHOD

    case "$PULL_SECRET_METHOD" in
      1)
        read -r -e -p 'Downloaded Pull Secret path in WSL: ' PULL_SECRET_SOURCE
        [[ -s "$PULL_SECRET_SOURCE" ]] || {
          echo "ERROR: File not found or empty: $PULL_SECRET_SOURCE" >&2
          exit 1
        }
        install -m 600 "$PULL_SECRET_SOURCE" "$PULL_SECRET"
        ;;
      2)
        umask 077
        vi "$PULL_SECRET"
        ;;
      *)
        echo 'ERROR: Select 1 or 2.' >&2
        exit 1
        ;;
    esac
  fi

  jq empty "$PULL_SECRET"
  chmod 600 "$PULL_SECRET"
  stat -c '%a %n' "$PULL_SECRET"
)
```

`jq empty`が無言で終了し、`stat`の先頭が`600`なら正常です。方法1を選んだ場合、入力待ちには`/mnt/c/Users/<Windowsユーザー>/Downloads/pull-secret.txt`のような実在するWSLパスを入力します。Windows側に残ったダウンロードファイルは、WSL側への保存と検証が終わった後、不要であればWindowsから削除します。

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

## 12. 構築前検査を実行する

ここまでの準備を自動検査します。この検査が合格するまでTerraformの初期化やPlan作成へ進みません。

```bash
cd "$LAB_ROOT"
bash scripts/02-03-preflight.sh
```

最後に次の3行が表示されることを確認します。`Failures`または`Warnings`が1以上の場合は03章へ進まず、表示された項目を解消して同じ検査を再実行します。

```text
Failures: 0
Warnings: 0
Preflight PASSED. It is safe to continue to Terraform planning.
```

## 次へ進む条件

- `aws sts get-caller-identity --profile openshift-lab` が成功する。
- 正確な`4.21.26`の`oc`と`openshift-install`が利用できる。
- 専用SSH鍵とPull Secretがリポジトリ外にある。
- EC2 vCPUクォータと対象AZのインスタンス提供状況を確認済み。
- `lab.k8study.com` Hosted Zone IDを特定済み。
- 保存済みaccount guardがあり、ログイン中のAccount IDと一致する。
- `LAB_ROOT`が現在の`upi-lab`ディレクトリを指す。
- `scripts/02-03-preflight.sh`が`Failures: 0`、`Warnings: 0`で合格した。

すべて満たしたら[03. Terraformネットワーク基盤](03-terraform-network.md)へ進みます。
