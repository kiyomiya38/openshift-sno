# 09. トラブルシューティング

## 基本原則

再作成する前に証拠を保存します。DNS、時刻、通信経路、HAProxyバックエンド、Ignitionの順に確認すると、原因を混同しにくくなります。

## AWS認証に失敗する

```bash
aws configure list-profiles
aws configure list --profile openshift-lab
aws sts get-caller-identity --profile openshift-lab
```

確認点:

- コマンドをWindowsではなく、設定したWSL Ubuntuで実行しているか。
- プロファイル名の綴りが一致しているか。
- アクセスキーが無効化されていないか。
- PC時刻が大きくずれていないか。

## Client VPNへ接続できない

確認順序:

1. Endpointが`available`か。
2. `infra-a`と`infra-b`の2つのtarget network associationが`associated`か。
3. 両associationに`10.80.0.0/16`へのrouteがあるか。
4. authorization ruleがあるか。
5. クライアント証明書がCAで署名され、期限内か。
6. Endpointとserver証明書が同じリージョンか。
7. Security GroupがVPNクライアントから必要通信を許可しているか。

Client VPN CIDRとVPC、関連routeが重複している場合はEndpointを作り直す必要があります。

### Windowsで「ポートは別のプロセスですでに使用」と表示される

```text
VPNプロセスの開始に失敗しました。ポートは別のプロセスですでに使用されています。
```

`OvpnPortTakenException`は、実際のポート競合以外でも表示されます。AWS VPN Clientの`WinServiceLogs`に次がある場合は、`.ovpn`内の`verify-x509-name`が不正です。

```text
Options error: Unrecognized option or missing or extra parameter(s): verify-x509-name
```

`scripts/04-06-export-client-vpn-config.sh`を再実行し、AWS VPN Clientの既存プロファイルを削除して、新しい`.ovpn`をインポートします。このスクリプトは空白を含むCA名を引用符付きへ自動補正します。

上記の設定エラーがない場合は、Windows PowerShellでポート443の所有プロセスを特定します。

```powershell
Get-NetTCPConnection -State Listen -LocalPort 443 |
  Select-Object LocalAddress,LocalPort,OwningProcess

Get-Process -Id (Get-NetTCPConnection -State Listen -LocalPort 443).OwningProcess |
  Select-Object Id,ProcessName,Path
```

Rancher Desktopの`host-switch.exe`であれば、Rancher Desktopをタスクトレイから完全終了して再接続します。用途不明のプロセスは強制終了しません。

## DNSが引けない

```bash
cat /etc/resolv.conf
dig @10.80.40.11 api.ocp.lab.k8study.com A
dig @10.80.50.11 api.ocp.lab.k8study.com A
dig @10.80.40.11 -x 10.80.10.10
```

確認点:

- Client VPNにBIND 2台のDNS IPを指定しているか。
- BINDがVPN CIDRとVPC CIDRからのqueryを許可しているか。
- 正引きゾーンserialを更新したか。
- 2台のauthoritative DNSへAnsibleで同じゾーン内容とSOA serialが配布されているか。
- Security GroupとNetwork ACLがTCP/UDP 53を許可しているか。

1回だけ`unexpected A/PTR record`になった場合は、両DNSの実応答とSOA serialを確認します。

```bash
dig +short @10.80.40.11 control-plane-2.ocp.lab.k8study.com A
dig +short @10.80.50.11 control-plane-2.ocp.lab.k8study.com A
dig +short @10.80.40.11 ocp.lab.k8study.com SOA
dig +short @10.80.50.11 ocp.lab.k8study.com SOA
```

内容とserialが一致していれば、一時的な応答失敗の可能性があります。`scripts/06-08-validate-cluster-nodes.sh`は各問い合わせを最大5回再試行します。再実行しても失敗する場合は、ノードを作り直さず表示された実応答を調査します。

## `bootstrap-complete`がタイムアウトする

確認順序:

1. `api`と`api-int`がNLB IPへ解決する。
2. NLB listener `6443`と`22623`が存在する。
3. NLBからHAProxy 2台のhealth checkが成功する。
4. HAProxyにBootstrapとControl Plane 3台が登録されている。
5. ノードからDNS、NTP、Proxyへ到達できる。
6. Ignitionが正しいroleへ割り当てられている。
7. EC2 serial consoleまたはsystem journalでRHCOS起動エラーを確認する。

Bootstrapを削除してやり直す前に、`openshift-install`のdebug logと全HAProxy状態を保存します。

## Ignitionを取得できない

まず、ノードを再作成せず次を確認します。

```bash
cd "$LAB_ROOT"
bash scripts/06-05-validate-cluster-prerequisites.sh

terraform -chdir=terraform output cluster_dhcp_options_id
terraform -chdir=terraform output openshift_instances
```

Installer側:

```bash
ssh -i ~/.ssh/openshift_upi_lab ec2-user@10.80.40.10
sudo systemctl status httpd
sudo httpd -t
sudo journalctl -u httpd --since '-30 minutes'
sudo ss -lntp | grep ':8080'
```

確認点:

- VPCへCluster用DHCP Optionsが関連付いているか。
- RHCOSがBIND 2台から`api-int`とInstallerを解決できるか。
- InstallerへIgnition Server用Security Groupが付いているか。
- Node用Security GroupからInstallerのTCP 8080だけが許可されているか。
- URLのInfrastructure IDとApache配下のディレクトリが一致するか。
- `SHA512SUMS`と3種類のIgnitionが一致するか。
- 生成から12時間以上経過した古い資材を使っていないか。

EC2 serial outputは次で保存できます。

```bash
aws ec2 get-console-output \
  --profile openshift-lab \
  --region ap-northeast-3 \
  --instance-id <instance-id> \
  --latest \
  --output text
```

`verification failed`ならURL先のファイルとTerraformへ渡したSHA-512の組み合わせが違います。既存ノードへ別Ignitionを混在させず、ログを保存してから再構築方針を決めます。

## HAProxy片系停止直後にNLB経由の接続が一度失敗する

全Target Groupが片系へ収束した直後でも、NLBデータプレーン側の反映がわずかに遅れ、`curl: (28)`やconnection resetが一時的に発生する場合があります。Target Health APIが片系を`healthy`と返したことだけでは継続性試験の合格にしません。

`scripts/07-04-test-haproxy-failover.sh`は、3つのNLB固定IPごとにAPIとConsoleを再試行し、各経路が3回連続で成功することを要求します。最大24回の範囲で回復すれば収束中の一時失敗として記録し、連続成功しなければ試験を不合格にして停止対象を自動復旧します。

同様の不合格後は自動復旧の完了、marker削除、全Target Groupの`2/2 healthy`を確認し、**同じ対象**を新しいpreflightから再試験します。

```bash
bash scripts/07-04-test-haproxy-failover.sh --preflight-only haproxy-1
```

上記は`haproxy-1`を再確認する例です。対象が`haproxy-0`なら末尾だけを置き換えます。

- 終了コードが`0`以外であったことを隠して合格扱いにしない。
- 復旧markerが削除され、両HAProxyが`running`かつstatus check正常である。
- 全4 Target Groupが`2/2 healthy`へ戻っている。
- `scripts/06-15-validate-openshift-cluster.sh`が`Failures: 0`である。

タイムアウトが同じNLB IP・同じportで繰り返す場合は、単なる収束遅延として扱わず、NLB listener、Target Group、Security Group、HAProxy frontend/backend、Ingress Routerを調査します。

## Worker再起動試験が中断する

`aws ec2 reboot-instances`は非同期であり、再起動中もEC2 Instance stateが`running`のままの場合があります。`instance-running`やNodeのAgeだけを完了判定にせず、`scripts/07-05-test-worker-reboot.sh`が保存した再起動前の`bootID`と、現在の`.status.nodeInfo.bootID`を比較します。

```bash
export KUBECONFIG="$HOME/.local/share/openshift-upi-lab/install/auth/kubeconfig"
oc get node worker-0.ocp.lab.k8study.com \
  -o jsonpath='{.status.nodeInfo.bootID}{"\n"}'
jq '{target_name,stage,boot_id_before,boot_id_after,reboot_may_have_been_requested}' \
  "$HOME/.config/openshift-upi-lab/worker-reboot-recovery.json"
```

対象Nodeが`Ready,SchedulingDisabled`で、MCO annotationが`currentConfig == desiredConfig`かつ`state=Done`でも、手動cordon中のworker MCPは通常、`machine=3 / ready=2 / updated=3 / unavailable=1 / degraded=0`、`Updated=False / Updating=True / Degraded=False`になります。これはcordonされたNodeをMCPがunavailableとして数えるためで、Node再起動の失敗ではありません。`scripts/07-05-test-worker-reboot.sh`はこの限定状態をuncordon前の正常な保守状態として扱い、uncordon後に厳格な3/3を確認します。

古い実行プロセスがこの状態で`Waiting for MCP...`を繰り返している場合は、別の試験や手動uncordonを重ねません。元のプロセスが終了してプロンプトへ戻り、markerが保持されていることを確認してから、修正版の`--recover`を1回実行します。

drainがPodDisruptionBudgetまたは管理元のないPodで停止した場合は、`--disable-eviction`や`--force`を追加しません。reboot未送信ならEXIT trapが対象をuncordonします。markerが残った場合は、Nodeを手動でuncordonしたりmarkerを削除したりせず、次を実行します。

```bash
bash scripts/07-05-test-worker-reboot.sh --recover
```

NodeがReadyへ戻らない場合はmarkerを保持して次のWorkerへ進まず、証拠を取得します。

```bash
oc describe node <node-fqdn>
oc get events -A --sort-by=.lastTimestamp
oc get csr
oc get mcp
oc get co
aws ec2 get-console-output \
  --profile openshift-lab \
  --region ap-northeast-3 \
  --instance-id <instance-id> \
  --latest \
  --output text
```

Pending CSRがある場合は自動承認しません。`scripts/06-13-review-csrs.sh`でrequestor、signer、Node名、IP、Instance IDを個別確認した後、`--recover`を再実行します。Ignitionの再生成、Node削除、EC2 terminate、Terraformによる置換は通常の再起動復旧に含めません。InstallerのIgnition HTTP配信は停止済みであるため、安易なEC2置換では新Nodeを復旧できません。

## OpenShiftインストール章のPlan検査が失敗する

専用Planスクリプトはaction allowlistと件数を検査します。想定外のactionが出た場合、直接applyしません。

新規構築で文書の期待件数と異なる場合はApplyしません。旧配布版のstateを意図的に継続している場合だけ、[移行ノート](upgrade-notes.md)の該当パターンを確認します。

```bash
terraform -chdir=terraform show cluster-prerequisites.tfplan
terraform -chdir=terraform show cluster-nodes.tfplan
terraform -chdir=terraform show bootstrap-removal.tfplan
```

特にControl Plane/Workerの`delete`や`replace`、Client VPN DNSの`10.80.0.2`へのロールバック、基盤EC2/NLBの変更がないか確認します。古いPlanを修正して再利用せず、原因を直して専用Planスクリプトから再作成します。

## Nodeが追加されない

```bash
oc get csr
oc get nodes -o wide
oc get clusteroperators machine-config network
```

確認点:

- Worker用Ignitionを使用しているか。
- A/PTRレコードが同じホストを指しているか。
- CSRのノード名と固定IPがパラメーター表に一致するか。
- `api-int:22623`へ到達できるか。

CSRは名前だけを見て一括承認しません。

## ClusterOperatorがDegraded

```bash
oc get clusteroperator
oc describe clusteroperator <name>
oc get events -A --sort-by=.lastTimestamp
```

`Message`と関連NamespaceのPod logを保存します。複数Operatorが同時にDegradedの場合は、個別Operatorより先にDNS、API、時刻、Proxy、ストレージの共通基盤を疑います。

## `terraform destroy`が完了しない

`scripts/08-02-apply-destroy.sh`が次で停止した場合、Terraform Applyはまだ開始されていません。

```text
ERROR: 1 non-terminated Client VPN connection(s) remain.
```

旧版では`active or terminating Client VPN connection(s) remain`と表示されますが、対処は同じです。

WindowsのAWS VPN Clientを切断し、スクリプトが表示する`ConnectionId`、`Status`、`StatusMessage`を確認します。`terminating`ならAWS側の終了処理を待ちます。Windows側が切断済みなのに`active`のまま、または`failed-to-terminate`なら、[08章の手順5](08-destroy.md#5-windowsのclient-vpnを切断する)にある、ConnectionIdを照合して1件だけ終了する手順を使用します。`failed-to-terminate`が再発する場合はdestroyへ進まず、StatusMessage、IAM権限、AWS APIエラーを調査します。接続状態の確認・終了ではTerraform stateや保存済みdestroy Planは変わらないため、接続が消えた後は`08-01`で再Planせず、同じ`08-02`を再実行します。

`08-02`がstate lineage/serial、Plan SHA-256、Account、region、workspaceの不一致を報告した場合だけ、[08章の手順6.1](08-destroy.md#61-staleまたは不採用のdestroy-planを明示破棄する)でそのPlanを明示破棄して`08-01`から作り直します。

エラーに表示されたIDを記録し、AWSコンソールから依存リソースを手動削除しません。典型的な依存関係:

- Subnetを消す前にClient VPN association、NLB ENI、NAT Gatewayを削除。
- VPCを消す前にENI、Security Group、Route、Endpointを削除。
- ACM証明書を消す前にClient VPN Endpointから参照を外す。
- Hosted Zoneを消さない。

Terraform Apply開始後の依存エラーを解消した後は、`scripts/08-01-plan-destroy.sh`からPlanを作り直します。state外リソースやstate破損が原因で手動介入が不可避な場合は、対象Account/region/resource IDを複数人で確認し、操作記録とstate復旧方針を作成してから管理者が対応します。

`Saved plan is stale`は、Plan作成後にstateが変わったことを示します。古い`destroy.tfplan`を適用せず、次を再実行します。

```bash
bash scripts/08-01-plan-destroy.sh --discard-saved-plan
bash scripts/08-01-plan-destroy.sh
```

Planが再作成できたら、[08章の手順4](08-destroy.md#4-保存済みdestroy-planをレビューする)へ戻ります。全resource addressの人手レビューと[手順5](08-destroy.md#5-windowsのclient-vpnを切断する)のVPN切断を完了した後だけ、手順6のApplyを実行します。

## ローカルarchive後にcleanup markerが見つからない

`scripts/08-05-clean-local-artifacts.sh --archive`が成功すると、`cleanup-validated.json`も生成物と一緒にアーカイブへ移ります。その後、元のパスに対して通常の`--delete`や`--include-pki`を実行すると、次の安全停止になります。

```text
ERROR: Local artifacts were already archived, so the active cleanup marker is no longer present.
```

これはAWS cleanupの失敗ではありません。`--archive`と通常の`--delete`は択一であり、元の生成物はすでに隔離済みです。既存アーカイブへ保持PKIを追加する場合は[08章の手順10.1](08-destroy.md#101-アーカイブ後に保持pkiを同じ場所へ隔離する)、アーカイブ全体を永久削除する場合は[手順10.2](08-destroy.md#102-隔離済みアーカイブを後から永久削除する)を使用します。cleanup markerを手動で元へ戻したり、元のパスを直接再帰削除したりしません。
