# 04. Terraformネットワーク基盤

## この章の目的

TerraformでVPC、9 Subnet、Internet Gateway、NAT Gateway、Elastic IP、Route TableをPlanし、検査済みPlanだけをApplyします。既存Public Hosted Zoneはdata sourceで読み取るだけです。Phase 1はPlan、Phase 2はApplyと検証です。

この章のplannerはmanaged stateが空の新規構築だけを受け付けます。後続フェーズ完了後は再実行せず、フェーズ専用plannerまたは[部分構築からの完全削除](08-validation-and-destroy.md#63-destroy-planを作成する)を使用します。

## 作成する範囲

- VPC `10.80.0.0/16`
- Cluster、Infra、Public egress Subnet各3個
- Internet Gateway
- NAT Gateway 1個とElastic IP 1個
- Public/Private Route Table、default route、Subnet association
- 既存`lab.k8study.com` Public Hosted Zoneの読み取り

Public SubnetもEC2のPublic IPv4自動割り当ては無効です。Public SubnetはNAT Gateway配置用です。

## 1. identityとaccount guardを確認する

実行場所: WSL Ubuntu

```bash
cd "$LAB_ROOT"

aws sts get-caller-identity --profile openshift-lab
aws configure get region --profile openshift-lab
test -s "$HOME/.config/openshift-upi-lab/expected-account-id"
bash scripts/00-preflight.sh
```

`Preflight PASSED.`を確認します。account guardは[02. 事前準備](02-prerequisites.md#2-aws-cliプロファイルを設定する)で、AWS loginとは別経路で承認したAccount IDから登録しておく必要があります。

## 2. Terraformを初期化する

```bash
terraform -chdir="$LAB_ROOT/terraform" init
test "$(terraform -chdir="$LAB_ROOT/terraform" workspace show)" = 'default'
```

`.terraform.lock.hcl`は配布リリースで検証したprovider checksumを保持します。意図せず更新しません。

このラボはlocal backendです。作業者を1人に限定し、Terraformを同時実行しません。`terraform.tfstate`とPlanは秘密情報に準じて扱います。stateを失うと安全な完全削除が困難になるため、AWS cleanup合格前に削除しません。

## 3. Network Planを作成する

```bash
cd "$LAB_ROOT"
bash scripts/00a-plan-network.sh
```

plannerは次を自動検査します。

- Terraform workspaceが`default`。
- 登録済みAccount ID、AWS login、`ap-northeast-3`が一致。
- managed stateが空。
- `fmt -check`と`validate`が成功。
- 26件すべてが許可リストどおりの`create`。
- `update`、`delete`、`replace`、未知のresource addressがない。

合格時だけ`terraform/network.tfplan`が保存されます。

```text
Network Plan validation PASSED.
Expected summary: 26 to add, 0 to change, 0 to destroy.
```

Planファイルには構成値が含まれるため、Git、チャット、配布物へ含めません。

## 4. Planをレビューする

plannerの合格は人による確認を置き換えません。

```bash
terraform -chdir="$LAB_ROOT/terraform" show -no-color network.tfplan
```

次を確認します。

- Account、region、VPC CIDR、9 Subnet CIDR/AZが設計表と一致。
- NAT GatewayとElastic IPが各1件。
- 全SubnetのPublic IPv4自動割り当てが無効。
- 既存Public Hosted Zoneの作成、変更、削除、importがない。
- 認識していない課金リソースがない。

1つでも一致しない場合は`scripts/00b-apply-network.sh`を実行しません。Planを手作業で編集せず、原因を修正してplannerから作り直します。

## 5. 保存PlanをApplyする

NAT GatewayとElastic IPを含む料金が始まります。

```bash
cd "$LAB_ROOT"
bash scripts/00b-apply-network.sh
```

Applyスクリプトは保存Planのexact action allowlistとAccountを再検証します。作成対象を再確認し、次を正確に入力します。

```text
APPLY-NETWORK
```

成功後、使用済みPlanは削除されます。Apply中に失敗した場合はAWSコンソールで補正せず、エラー全文とstateを保存します。

## 6. ネットワークを検証する

```bash
cd "$LAB_ROOT"
bash scripts/01-validate-network.sh
```

合格時:

```text
Failures: 0
Network validation PASSED.
```

検査内容は次です。

- Terraform managed resourceが最低26件、data sourceが最低2件。
- VPCが`available`、CIDRが`10.80.0.0/16`。
- 9 Subnetが3 AZへ配置され、Public IPv4自動割り当てがすべて無効。
- NAT Gatewayが`available`。
- Internet Gatewayとpublic/private default routeが有効。

## 完了条件

- Network Planがexact 26-create allowlistで合格。
- Applyスクリプトが完了し、使用済みPlanが削除された。
- `scripts/01-validate-network.sh`が`Failures: 0`。
- 既存Public Hosted Zoneと他用途リソースを変更していない。

すべて満たした場合は[05. AWS Client VPN](05-client-vpn.md)へ進みます。
