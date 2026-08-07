# 07. OpenShift UPIインストール

Phase 6では保存済みPlanだけをapplyします。通常の`terraform plan`や`terraform apply`を直接実行しません。

## 実装方式

このラボではAWS EC2をオンプレミス機器に見立て、`platform: none`のUPIとして構築します。

- Installer `10.80.40.10`の内部HTTPからIgnitionを配信する。
- 完全なIgnitionはリポジトリとTerraform stateへ保存しない。
- EC2 user dataには、配布URL、SHA-512、ノード固有FQDNだけを含む小さいIgnition wrapperを渡す。
- VPC DHCP Optionsで、初回起動時からBIND `10.80.40.11`、`10.80.50.11`とNTPを使わせる。
- Bootstrap 1台、Control Plane 3台、Worker 3台を同じノード起動段階で作成する。
- Bootstrap完了後は、HAProxyとDNSから切り離してからBootstrap EC2だけを削除する。
- CSRは内容を確認し、1件ずつ明示承認する。一括承認しない。

内部HTTPは暗号化されません。通信元Security Group、Apacheの送信元制限、SHA-512検証を組み合わせています。本番ではHTTPSと専用CAも検討します。

## 作業を始める前の確認

実行場所: AWS Client VPN接続済みWSL Ubuntu

```bash
cd "$LAB_ROOT"

bash scripts/10-validate-infrastructure-services.sh
bash scripts/10c-validate-client-vpn-dns.sh

dig @10.80.40.11 api-int.ocp.lab.k8study.com A
dig @10.80.50.11 test.apps.ocp.lab.k8study.com A
```

両スクリプトが`PASSED`し、DNSがNLBの3アドレスを返すことが前提です。

## 1. install-configとRHCOS AMIを準備する

```bash
bash scripts/15-prepare-openshift-install.sh
```

このスクリプトは次を行います。

- Pull SecretとSSH公開鍵をローカルファイルから読み込む。
- 既定のOpenShift `4.21.26`用`install-config.yaml`をリポジトリ外へ生成する。
- Proxyを`http://10.80.40.31:3128`へ設定する。
- `compute.replicas: 0`、`controlPlane.replicas: 3`、`platform: none`を設定する。
- 使用中の`openshift-install`から対応RHCOS AMIを取得し、Owner、状態、アーキテクチャをAWSで検証する。
- 古いinstallディレクトリがあれば、削除せず日時付きディレクトリへ退避する。

保存場所:

```text
~/.local/share/openshift-upi-lab/install/install-config.yaml
~/.local/share/openshift-upi-lab/install-config.backup.yaml
~/.local/share/openshift-upi-lab/cluster.env
```

これらには秘密情報が含まれるため、Gitへ追加しません。この段階ではManifest、Ignition、EC2は作成されません。ここは安全に作業を中断できるチェックポイントです。

## 2. クラスタ前提リソースのPlanを作る

```bash
bash scripts/16-plan-cluster-prerequisites.sh
```

完全削除後にPhase 4から作り直した通常構築の期待値:

```text
Plan: 13 to add, 0 to change, 0 to destroy.
Cluster prerequisite Plan validation PASSED.
```

作成対象は、Cluster用DHCP Options、Nodeと役割別Security Group、Ignition通信を許可するルールです。Installer専用のIgnition Server用Security GroupはPhase 4で作成・装着済みです。

新規構築でこの期待値と異なる場合はApplyしません。以前の配布版からstateを継続する場合だけ、[移行ノート](upgrade-notes.md)を確認します。

次がPlanに含まれた場合はapplyしません。

- OpenShift EC2インスタンス
- 既存Control Planeや基盤EC2の削除・置換
- VPC、NAT Gateway、Client VPN、NLBの削除・置換
- Public Hosted Zoneの変更

## 3. クラスタ前提リソースをapplyする

保存済みPlanをapplyします。

```bash
bash scripts/17-apply-cluster-prerequisites.sh
```

表示されたら、次をそのまま入力します。

```text
APPLY-CLUSTER-PREREQUISITES
```

成功後、使用済みPlanは削除されます。

`Cluster prerequisite application is complete.`を確認してから手順4へ進みます。Ignition生成スクリプトも、Installerへ専用Security Groupが実際に割り当てられていなければ停止します。

## 4. ManifestとIgnitionを生成・配信する

```bash
bash scripts/18-generate-stage-ignition.sh
```

このスクリプトは次を行います。

1. Manifestを生成する。
2. `mastersSchedulable: false`を検査する。
3. `bootstrap.ign`、`master.ign`、`worker.ign`を生成する。
4. 3ファイルのIgnition仕様バージョン一致とSHA-512を検査する。
5. AnsibleでInstallerのApacheへ配置する。
6. Apacheを`10.80.40.10:8080`だけで待ち受けさせる。
7. Directory Indexを無効化し、Cluster subnetからだけ取得可能にする。

生成済みIgnitionには短命な証明書が含まれます。このラボでは生成後12時間以内にノードを起動します。翌日へ持ち越す場合は再利用せず、Phase 6を最初からやり直します。

## 5. 起動前検証を行う

```bash
bash scripts/19-validate-cluster-prerequisites.sh
```

合格条件:

- VPCにCluster用DHCP Optionsが関連付いている。
- DNSとNTPがBIND/chrony 2台を指している。
- 両BINDが`api-int`と`*.apps`を正しく返す。
- 3種類のIgnitionがInstallerの内部HTTPから取得できる。
- ローカルIgnitionのSHA-512が一致する。
- OpenShift EC2がまだ0台である。

`Cluster prerequisite validation PASSED.`を確認してから進みます。

## 6. 7台のOpenShiftノードをPlanする

```bash
bash scripts/20-plan-cluster-nodes.sh
```

期待値:

```text
7 to add, 0 to change, 0 to destroy
```

作成対象は次の7台だけです。

| ノード | Private IP | AZ | Ignition |
|---|---:|---|---|
| bootstrap | `10.80.10.30` | 3a | bootstrap |
| control-plane-0 | `10.80.10.10` | 3a | master |
| control-plane-1 | `10.80.20.10` | 3b | master |
| control-plane-2 | `10.80.30.10` | 3c | master |
| worker-0 | `10.80.10.20` | 3a | worker |
| worker-1 | `10.80.20.20` | 3b | worker |
| worker-2 | `10.80.30.20` | 3c | worker |

全台`m6i.xlarge`、暗号化gp3、Public IPv4なし、IMDSv2必須です。このapplyからEC2とEBSの追加課金が始まります。

## 7. 7台のOpenShiftノードを起動する

```bash
bash scripts/21-apply-cluster-nodes.sh
```

確認文字列:

```text
APPLY-OPENSHIFT-NODES
```

この時点からBootstrap完了まで、Ignitionを再生成せず、Installer、DNS、HAProxy、Proxy、NLBを停止しません。

## 8. EC2とDNSを検証する

```bash
bash scripts/22-validate-cluster-nodes.sh
```

固定IP、Public IPv4なし、RHCOS AMI、IMDSv2、全ノードのA/PTRを検証します。成功後はBootstrap完了を待ちます。

## 9. Bootstrap完了を待つ

```bash
bash scripts/23-wait-for-bootstrap.sh
```

ログは次へ保存されます。

```text
~/.local/share/openshift-upi-lab/install/bootstrap-complete.log
```

`Bootstrap completion PASSED.`が表示された場合だけ次へ進みます。失敗時にノードを即再作成せず、[09. トラブルシューティング](09-troubleshooting.md)に従って証拠を確認します。

## 10. HAProxyとDNSからBootstrapを切り離す

この工程と次のBootstrap削除は、途中で中断しない作業枠で続けます。

```bash
bash scripts/24-cutover-from-bootstrap.sh
```

Ansibleは次の順序で処理します。

1. HAProxy 2台からControl Plane 3台のAPI/MCSを直接検査する。
2. HAProxyを1台ずつreloadし、Bootstrap backendを除く。
3. 両HAProxy経由のAPI/MCSを再検査する。
4. BIND 2台からBootstrap A/PTRを除く。

Control Plane起動直後は`/readyz`が一時的にHTTP 500を返す場合があります。切り替え前と切り替え後のAPI/MCS検査は最大12回、5秒間隔で再試行し、継続して正常性を確認できない場合はHAProxyとDNSを変更せず停止します。
5. Bootstrapが設定とDNSに残っていないことを検査する。

通常の基盤Ansible再実行でもBootstrapを再登録しないよう、stageはリポジトリ外へ保存されます。

## 11. Bootstrap EC2だけを削除する

```bash
bash scripts/25-plan-bootstrap-removal.sh
```

期待値:

```text
0 to add, 0 to change, 1 to destroy
```

削除対象が`aws_instance.openshift["bootstrap"]`の1件だけであることをスクリプトが検査します。続けて実行します。

```bash
bash scripts/26-apply-bootstrap-removal.sh
```

確認文字列:

```text
REMOVE-BOOTSTRAP
```

## 12. CSRを個別確認・承認する

```bash
bash scripts/27-review-csrs.sh
```

スクリプトはSigner、Requestor、Subject、SANを表示します。設計表のFQDNと固定IPに一致する場合だけ、表示されたCSR名を正確に入力して承認します。

Client CSR承認後にServing CSRが現れるため、このスクリプトを複数回実行します。次を満たすまで繰り返します。

承認待ちの間に同じノードのClient CSRが再生成される場合があります。Signer、Requestor、Subjectが設計値と一致するものは、重複分も含めて個別に確認・承認します。Serving CSRはさらにDNS SANと固定IP SANを照合してから承認します。

- Control Plane 3台とWorker 3台が`Ready`。
- 想定ノードの未承認CSRがない。
- 不明なRequestor、FQDN、IPのCSRを承認していない。

## 13. インストール完了を待つ

```bash
bash scripts/28-wait-for-install-complete.sh
```

6台がReadyであることを事前確認し、`install-complete`を待ちます。成功後はInstallerのIgnition HTTPサービスを停止し、公開中のクラスタ固有Ignitionを削除します。ローカルのIgnitionとkubeconfigはリポジトリ外に保持されます。

## 14. 完成したクラスターを検証する

```bash
bash scripts/29-validate-openshift-cluster.sh
```

合格条件:

- 6 NodeがReady。
- ClusterVersionがAvailable。
- 全ClusterOperatorがAvailableで、Progressing/Degradedではない。
- Pending CSRがない。
- APIとConsole RouteへVPN経由で到達できる。
- NLBの4 Target GroupでHAProxy 2台がhealthy。
- Terraform stateに永久ノード6台だけが存在し、Bootstrapがない。

一時的にOperatorがProgressingの場合は、状態が収束してから再実行します。

## 中断可能な位置

| 位置 | 中断 |
|---|---|
| スクリプト15完了後、Ignition生成前 | 可 |
| スクリプト18完了後、ノード起動前 | 同じ作業枠で続行を推奨。12時間を超えたら再生成 |
| ノード起動後からbootstrap-completeまで | 原則中断しない |
| HAProxy切り離しからBootstrap削除まで | 中断しない |
| Bootstrap削除後 | 可。ただしCSRは早めに確認 |
| install-complete後 | 可 |

## 失敗・翌日再開時の原則

- 新しいシェルでは`LAB_ROOT`、`EXPECTED_AWS_ACCOUNT_ID`、AWS profile、必要なsecret環境変数を再設定する。
- 保存Planを作成した後にstate、workspace、AWS認証、Terraform定義を変更した場合、そのPlanをApplyせず同じplannerから作り直す。
- スクリプト18で作成したinstallディレクトリ、Ignition、`cluster.env`を別の構築へ流用しない。12時間を超えた場合は新しいinstall-configからPhase 6をやり直す。
- ノード起動後の失敗では、`bootstrap-complete.log`、EC2 console output、該当サービスログを保全する。原因を確認せずEC2を再作成しない。
- スクリプト24が失敗した場合は、成功するまでスクリプト25へ進まない。Bootstrap削除Planが既にある場合も、切り替え検証をやり直してからPlanを作り直す。
- Pending CSRはスクリプト27で設計表と照合し、一括承認しない。
- 構築を断念する場合は、手動削除せず[完全削除](08-validation-and-destroy.md#6-完全削除)へ進む。

## 注意事項

- `platform: none`ではMachine API、AWS CCM、自動LoadBalancer作成などAWS統合機能を利用できません。
- `compute.replicas`はUPIのため`0`です。実際のWorker 3台はTerraformで手動作成します。
- Pull Secret、Ignition、kubeconfig、kubeadmin情報をチャット、Git、共有フォルダーへ貼り付けません。
- Control PlaneやWorkerの置換・削除を含むPlanはapplyしません。
- 毎日の完全削除後は、古いIgnitionやkubeconfigを次のクラスターへ再利用しません。
