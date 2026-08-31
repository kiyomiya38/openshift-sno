# 03. Terraformネットワーク基盤

## この章の目的

TerraformでVPC、9 Subnet、Internet Gateway、NAT Gateway、Elastic IP、Route TableをPlanし、検査済みPlanだけをApplyします。既存Public Hosted Zoneはdata sourceで読み取るだけです。

この章のplannerはmanaged stateが空の新規構築だけを受け付けます。既存の`network.tfplan`がある場合は、Account、state、許可actionを再検査して再利用し、Planを上書きしません。後続章の作業を開始した後は再実行しません。

## 作成する範囲

- VPC `10.80.0.0/16`
- Cluster、Infra、Public egress Subnet各3個
- Internet Gateway
- NAT Gateway 1個とElastic IP 1個
- Public/Private Route Table、default route、Subnet association
- 既存`lab.k8study.com` Public Hosted Zoneの読み取り

Public SubnetもEC2のPublic IPv4自動割り当ては無効です。Public SubnetはNAT Gateway配置用です。

02章末の構築前検査が`Failures: 0`、`Warnings: 0`で合格した後、次の手順を番号順に実行します。WSLを開き直した場合も、手順1で作業コンテキストを復元します。

## 1. Terraformを初期化する

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
  terraform -chdir="$LAB_ROOT/terraform" init
  test "$(terraform -chdir="$LAB_ROOT/terraform" workspace show)" = 'default'
else
  echo 'STOP: Terraform was not initialized.' >&2
fi
unset LAB_CONTEXT_READY
```

`PASS: WSL work context is ready.`が表示されない場合は、Terraformを実行せず02章の手順1へ戻ります。

`.terraform.lock.hcl`は配布リリースで検証したprovider checksumを保持します。意図せず更新しません。

このラボはlocal backendです。作業者を1人に限定し、Terraformを同時実行しません。`terraform.tfstate`とPlanは秘密情報に準じて扱います。stateを失うと安全な完全削除が困難になるため、AWS cleanup合格前に削除しません。

## 2. Network Planを作成する

```bash
cd "$LAB_ROOT"
bash scripts/03-01-plan-network.sh
```

plannerは次を自動検査します。

- Terraform workspaceが`default`。
- 登録済みAccount ID、AWS login、`ap-northeast-3`が一致。
- managed stateが空。
- `fmt -check`と`validate`が成功。
- 26件すべてが許可リストどおりの`create`。
- `update`、`delete`、`replace`、未知のresource addressがない。
- 既存Planがある場合は、登録済みAccountと一致し、現在も同じ26-create allowlistである。

新規Planは合格時だけ`terraform/network.tfplan`として保存されます。既存Planが合格した場合は、再作成・上書きをせず手順3へ案内します。

Plannerが`ERROR:`を表示して非0で終了した場合は、その場で止め、Applyと後続検証を実行しません。既存Planを手動削除せず、表示されたAccount、state、actionまたは一時Planの問題を解消します。新規作成時のエラーではapply可能なPlanを保存しません。

```text
Network Plan validation PASSED.
Expected summary: 26 to add, 0 to change, 0 to destroy.
```

前回の保存Planを安全に再利用できる場合は、代わりに次が表示されます。

```text
Existing Network Plan validation PASSED. No Plan was regenerated or overwritten.
Expected summary: 26 to add, 0 to change, 0 to destroy.
```

Planファイルには構成値が含まれるため、Git、チャット、配布物へ含めません。

## 3. Planを人手でレビューする

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

1つでも一致しない場合は`scripts/03-02-apply-network.sh`を実行しません。Planを手作業で編集せず、原因を修正して手順2のplannerから作り直します。

## 4. 保存PlanをApplyする

NAT GatewayとElastic IPを含む料金が始まります。

```bash
cd "$LAB_ROOT"
bash scripts/03-02-apply-network.sh
```

Applyスクリプトは保存Planのexact action allowlistとAccountを再検証します。作成対象を再確認し、次を正確に入力します。

```text
APPLY-NETWORK
```

成功後、使用済みPlanは削除されます。Apply中に失敗した場合はAWSコンソールで補正せず、エラー全文とstateを保存します。

## 5. ネットワークを検証する

```bash
cd "$LAB_ROOT"
bash scripts/03-03-validate-network.sh
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
- `scripts/03-03-validate-network.sh`が`Failures: 0`。
- 既存Public Hosted Zoneと他用途リソースを変更していない。

すべて満たしたら[04. AWS Client VPN](04-client-vpn.md)へ進みます。
