# 03. AWS アカウントと認証

account root の access key は絶対に使わず、MFA を有効にした専用の学習用 IAM principal を使います。重要な違いとして、本教材の標準 IPI（`credentialsMode` を変更しない方式）は、インストール時だけでなくクラスター存続中も AWS API を操作できる key-based の長期 credential を必要とします。IAM Identity Center (SSO) の login や MFA で発行した一時 session token を、そのまま標準 IPI のクラウド credential として使う構成ではありません。

本教材の標準 IPI をそのまま実行する場合は、公式 4.21 手順に従って専用 IAM user の key-based credential を WSL Ubuntu 内へ設定します。値は入力プロンプトだけに入力し、コマンド行や教材へ書きません。

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

`configs/environment` の `AWS_PROFILE="ocp-lab"` により、教材スクリプトも同じ profile を使います。Windows や Git Bash の `~/.aws` は WSL の Linux home と別なので、WSL 内で設定してください。

IAM Identity Center (SSO) は日常の AWS CLI 操作には推奨できますが、SSO login で得た一時 credential を本教材の標準 IPI credential としてそのまま使用しません。短期 credential を本格利用する場合は AWS STS の manual mode を別途設計してください。単に一時 token を export するだけでは代替になりません。

IPI には EC2、ELBv2、IAM、Route 53、S3、KMS、Service Quotas 等への広い作成・参照・削除権限が必要です。正確な action 一覧は対象 minor の [AWS account configuration](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_aws/index) を採用し、推測したポリシーを使いません。

```bash
bash scripts/02-check-aws-credentials.sh
bash scripts/03-check-service-quotas.sh
```

Account ID や ARN を教材画面へそのまま貼らないでください。次: [DNS](04-domain-and-route53.md)

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

