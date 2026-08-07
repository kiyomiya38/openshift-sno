# OpenShift on AWS 学習リポジトリ

このリポジトリには、目的と構築方式が異なる2つのラボが含まれます。最初に対象を選び、選択したラボのREADMEだけを入口として進めてください。Terraform stateやインストール資材を2つのラボ間で共用しません。

| ラボ | 構築方式 | 構成 | 用途 | 入口 |
|---|---|---|---|---|
| SNOラボ | AWS IPI | Control Plane兼Worker 1台 | Single Node OpenShiftとAWS IPIの学習 | [SNO手順](docs/00-overview.md) |
| UPI模擬ラボ | `platform: none` UPI | Control Plane 3台＋Worker 3台 | DNS、HAProxy、Ignition、CSRなど利用者管理UPIの学習 | [UPI手順](upi-lab/README.md) |

## 重要な違い

- SNOラボはOpenShift InstallerがAWSリソースを作成・追跡します。
- UPI模擬ラボはTerraformとAnsibleでAWSをオンプレミス相当に見立て、利用者がノード、DNS、ロードバランサー、起動順序を管理します。
- UPI模擬ラボはAWSで正式に試験済みのIPI構成を再現するものではありません。本番環境やRed Hatのサポート対象構成として使用しません。
- どちらもAWS料金が発生します。EC2を停止するだけではNAT Gateway、Load Balancer、EBS、Elastic IPなどの課金は終了しません。

## 共通の安全ルール

- Pull Secret、AWS access key、SSH/VPN秘密鍵、kubeconfig、Ignition、Terraform state/PlanをGit、チャット、スクリーンショットへ含めません。
- AWS root userのaccess keyを使用しません。ラボ専用principalと最小権限を使用します。
- Apply/Destroy前にAWSアカウント、リージョン、Terraform workspace、Planのactionを確認します。
- AWSコンソールからTerraform管理リソースを手作業で追加・削除しません。
- 作業終了時は、選択したラボ固有の削除手順と残存リソース検査まで実施します。

## 配布物を作る場合

作業ディレクトリをそのままZIP化しないでください。`.terraform/`、`*.tfstate*`、`*.tfplan*`、ログ、`auth/`、kubeconfig、Ignition、VPN設定などは`.gitignore`対象でも、フォルダーコピーには含まれます。配布前に対象ラボのリリース検査を実施し、生成物を含まないクリーンなcheckoutから配布物を作成します。

ライセンスは[LICENSE](LICENSE)を参照してください。外部由来のマニフェストやコンテナーには、各上流プロジェクトのライセンスも適用されます。
