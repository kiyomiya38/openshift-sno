# 03. AWS アカウントと認証

## この章の目的

WSL Ubuntuにラボ専用のAWS credentialを設定し、後続スクリプトが読む `configs/environment` を初回作成します。

## 1. AWS credentialを設定する

AWS account rootのaccess keyは絶対に使わず、MFAを有効にした専用の学習用IAM principalを使います。重要な違いとして、本教材の標準IPI（`credentialsMode`を変更しない方式）は、インストール時だけでなくクラスター存続中もAWS APIを操作できるkey-basedの長期credentialを必要とします。IAM Identity Center (SSO)のloginやMFAで発行した一時session tokenを、そのまま標準IPIのクラウドcredentialとして使う構成ではありません。

本教材の標準IPIをそのまま実行する場合は、公式4.21手順に従って専用IAM userのkey-based credentialをWSL Ubuntu内へ設定します。値は入力プロンプトだけに入力し、コマンド行や教材へ書きません。

```bash
aws configure --profile ocp-lab
```

次の4項目を対話入力します。

```text
AWS Access Key ID: 専用IAMユーザーのAccess Key ID
AWS Secret Access Key: 対応するSecret Access Key
Default region name: ap-northeast-3
Default output format: json
```

Secret Access Keyは、パスワード管理ツールからターミナルの入力プロンプトへ直接貼り付けます。ターミナル出力全体をチャットや作業報告へコピーする前に、入力した秘密値が含まれていないか確認してください。

```bash
export AWS_PROFILE=ocp-lab
aws sts get-caller-identity
aws configure list
aws ec2 describe-regions --region ap-northeast-3
chmod 700 ~/.aws
chmod 600 ~/.aws/credentials ~/.aws/config
```

WindowsやGit Bashの `~/.aws` はWSLのLinux homeと別なので、必ずWSL内で設定してください。

## 2. 教材設定ファイルを初回作成する

WSLのプロンプトが `.../openshift-sno$` なら、既にリポジトリのルートにいるため `cd` は不要です。次のブロックは現在位置を検査し、既に `configs/environment` がある場合は上書きしません。

```bash
pwd

if [[ ! -f configs/environment.example || ! -d scripts ]]; then
  echo 'ERROR: Run this command from the openshift-sno repository root.' >&2
elif [[ -e configs/environment ]]; then
  echo 'Existing configs/environment was retained.'
else
  cp configs/environment.example configs/environment
  echo 'Created configs/environment.'
fi

if [[ -f configs/environment ]]; then
  chmod 600 configs/environment
fi
```

`ERROR` が表示された場合は、[前提条件](02-prerequisites.md)の手順でリポジトリの実際のパスへ移動してから再実行します。VS Codeなどのテキストエディターで `configs/environment` を開き、まず次の2項目をAWS CLIに設定した値と一致させます。

```bash
export AWS_REGION="ap-northeast-3"
export AWS_PROFILE="ocp-lab"
```

`configs/environment` は設定値の入力元であり、`.gitignore` によりGit管理から除外されています。Access KeyやSecret Access Keyはこのファイルへ記載しません。`BASE_DOMAIN` と `CLUSTER_NAME` は次章で実値を設定し、Pull SecretとSSH公開鍵のパスは[install-config.yaml](06-install-config.md)の章で確認します。

`scripts/01-check-prerequisites.sh` から `scripts/10-check-leftover-resources.sh` までの教材スクリプトは、このファイルを子プロセス内で自動的に読み込みます。ツール導入用の `scripts/00-install-client-tools.sh` だけは例外です。一方、手順書に直接記載された `$BASE_DOMAIN` や `$INSTALL_DIR` を使うコマンドでは、現在のシェルで `source configs/environment` が必要です。新しいWSLターミナルを開いた場合は、再度 `source` してください。

## 3. 認証とクォータを検査する

現在のシェルへ設定を読み込み、意図したprofileとregionであることを確認します。

```bash
source configs/environment
printf 'AWS_PROFILE=%s\nAWS_REGION=%s\n' "$AWS_PROFILE" "$AWS_REGION"

bash scripts/02-check-aws-credentials.sh
bash scripts/03-check-service-quotas.sh
```

IAM Identity Center (SSO)は日常のAWS CLI操作には推奨できますが、SSO loginで得た一時credentialを本教材の標準IPI credentialとしてそのまま使用しません。短期credentialを本格利用する場合はAWS STSのmanual modeを別途設計してください。単に一時tokenをexportするだけでは代替になりません。

IPIにはEC2、ELBv2、IAM、Route 53、S3、KMS、Service Quotas等への広い作成・参照・削除権限が必要です。正確なaction一覧は対象minorの[AWS account configuration](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_aws/index)を採用し、推測したポリシーを使いません。

Account IDやARNを教材画面、チャット、Issueへそのまま貼らないでください。

## 次の章へ進む条件

- `configs/environment` が存在し、permissionが `600` である。
- `AWS_PROFILE` と `AWS_REGION` が意図した値である。
- 認証検査が成功し、必要なService Quotaを確認できた。

次: [DNS](04-domain-and-route53.md)

## Access Keyを漏えいした場合

Secret Access KeyまたはAccess Keyの組を、チャット、Git、Issue、ログ、スクリーンショット、配信画面などへ出した場合は、漏えい済みとして扱います。投稿の削除だけでは、既に取得された可能性を排除できません。

1. 実行中の入力やインストールを `Ctrl+C` で停止する。
2. AWS Consoleで **IAM → Users → 対象ユーザー → Security credentials → Access keys** を開く。
3. 該当Access Keyを直ちに `Inactive` にする。
4. CloudTrail Event history、請求、作成資源を確認し、不審な操作があれば管理者へ連絡する。
5. 新しいAccess Keyを発行し、WSLで `aws configure --profile ocp-lab` を再実行する。
6. 新しいキーで動作確認後、古いキーを削除する。

確認では秘密値を出力しません。

```bash
export AWS_PROFILE=ocp-lab
aws sts get-caller-identity
aws configure list
```

古いキーのIDが分かる場合、管理権限を持つ別の安全なprincipalからCLIで無効化することもできますが、誤操作を避けるため本教材ではAWS Consoleから対象ユーザーとキー末尾を照合する方法を基本とします。新しいSecret Access Keyをこのリポジトリやチャットへ記録しないでください。
