# 04. ドメインと Route 53

## この章の目的

OpenShiftで使用する実ドメインを `configs/environment` に設定し、完全一致するRoute 53 Public Hosted Zoneと外部DNSの委任を確認します。

## 1. `$BASE_DOMAIN`の意味を理解する

`$BASE_DOMAIN` は、コマンドごとに文字列を手作業で置き換える記号ではありません。Bashが `configs/environment` に設定した値へ展開する環境変数です。変更する場所は、原則として `configs/environment` の右辺だけです。

次は値の対応を示すための説明例であり、ターミナルで実行するコマンドではありません。`example.jp` は予約ドメインなので、自分が所有するPublic Hosted Zone名を `configs/environment` に設定します。

| 設定項目 | 説明用の値 | 実際に設定する値 |
|---|---|---|
| `CLUSTER_NAME` | `ocp-sno` | 作成するクラスター名 |
| `BASE_DOMAIN` | `lab.example.jp` | 所有するPublic Hosted Zone名 |

この設定からOpenShift Installerは次の名前を使用します。

| 用途 | FQDN |
|---|---|
| クラスタードメイン | `ocp-sno.lab.example.jp` |
| 外部API | `api.ocp-sno.lab.example.jp` |
| 内部API | `api-int.ocp-sno.lab.example.jp` |
| アプリケーション | `*.apps.ocp-sno.lab.example.jp` |

`BASE_DOMAIN`にはPublic Hosted Zone名だけを設定します。`https://`、パス、末尾のドット、`api`、`apps`、`CLUSTER_NAME`を含めません。`example.jp`などの予約ドメインとそのサブドメインは説明専用であり、教材スクリプトは使用を拒否します。

## 2. クラスター名とbase domainを設定する

VS Codeなどのテキストエディターで `configs/environment` を開き、`CLUSTER_NAME` と `BASE_DOMAIN` を実値へ変更します。保存後、リポジトリのルートで次を実行します。

```bash
pwd
if [[ ! -f configs/environment ]]; then
  echo 'ERROR: Run this command from the openshift-sno repository root.' >&2
else
  source configs/environment

  printf 'CLUSTER_NAME=%s\n' "$CLUSTER_NAME"
  printf 'BASE_DOMAIN=%s\n' "$BASE_DOMAIN"
  printf 'CLUSTER_DOMAIN=%s.%s\n' "$CLUSTER_NAME" "$BASE_DOMAIN"
  printf 'API_FQDN=api.%s.%s\n' "$CLUSTER_NAME" "$BASE_DOMAIN"
  printf 'APPS_FQDN=*.apps.%s.%s\n' "$CLUSTER_NAME" "$BASE_DOMAIN"
fi
```

表示された値が意図どおりでなければ、先へ進まず `configs/environment` を修正して再度 `source` します。`source` の効果は新しいターミナルへ引き継がれません。

## 3. 完全一致するPublic Hosted Zoneを確認する

Route 53は同じ名前のPublic/Private Hosted Zoneや重複したHosted Zoneを保持できます。本教材では、`BASE_DOMAIN`に完全一致するPublic Hosted Zoneが1件だけ存在することを要求します。

```bash
ZONE_JSON="$(aws route53 list-hosted-zones --output json)"

PUBLIC_ZONE_COUNT="$(
  jq -r --arg name "${BASE_DOMAIN}." \
    '[.HostedZones[] | select(.Name == $name and .Config.PrivateZone == false)] | length' \
    <<<"$ZONE_JSON"
)"

printf 'Exact public hosted zones: %s\n' "$PUBLIC_ZONE_COUNT"
```

正常値は `1` です。`0` または `2` 以上の場合は先へ進みません。正常な場合だけ、同じターミナルでHosted Zone IDとRoute 53が割り当てた権威DNSサーバーを取得します。

```bash
if [[ "$PUBLIC_ZONE_COUNT" -ne 1 ]]; then
  echo 'ERROR: Exact public hosted zone count must be 1.' >&2
else
  ZONE_ID="$(
    jq -r --arg name "${BASE_DOMAIN}." \
      '.HostedZones[]
       | select(.Name == $name and .Config.PrivateZone == false)
       | .Id
       | sub("^/hostedzone/"; "")' \
      <<<"$ZONE_JSON"
  )"

  printf 'Hosted Zone ID: %s\n' "$ZONE_ID"
  aws route53 get-hosted-zone \
    --id "$ZONE_ID" \
    --query 'DelegationSet.NameServers' \
    --output table
fi
```

`PrivateZone`だけが存在する場合や、似た名前のHosted Zoneしかない場合は不合格です。

## 4. Hosted Zoneがない場合に作成する

AWS Consoleで **Route 53 → Hosted zones → Create hosted zone** を開きます。

1. Domain nameへ `BASE_DOMAIN`と完全に同じ名前を入力する。
2. Typeで **Public hosted zone** を選ぶ。
3. 同名のPublic Hosted Zoneがないことを再確認して、1回だけ作成する。

Hosted Zoneには料金が発生し、重複作成は委任先の取り違えにつながります。OpenShift Installerはbase domainの登録権やPublic Hosted Zoneそのものを用意しません。一方、クラスター固有のpublic/private DNS Zoneと `api`、`api-int`、`*.apps` レコードはインストール中に必要に応じて作成するため、この時点で手作業により先行作成しません。

## 5. DNS委任を確認する

委任先を設定する場所は、base domainの種類で異なります。

- 登録ドメインそのものをHosted Zoneにする場合: registrar（ドメイン登録事業者）のnameserver設定を、Route 53が割り当てた4台のNSへ変更する。
- `lab.example.jp`のようなサブドメインをHosted Zoneにする場合: 親の権威DNS Zone（例: `example.jp`）に、サブドメインをRoute 53の4台のNSへ委任するNSレコードを作成する。ここでのドメイン名は説明用であり、実際には所有するドメインを使う。

Route 53で登録したドメインでも、Hosted Zoneを作り直した場合はnameserver設定が新しいZoneへ自動追随するとは限りません。必ず実際の値を比較します。

次の確認は、手順3で `ZONE_ID` を設定した同じターミナルで行います。

```bash
ROUTE53_NS="$(
  aws route53 get-hosted-zone \
    --id "$ZONE_ID" \
    --query 'DelegationSet.NameServers' \
    --output text \
  | tr '\t' '\n' \
  | sed 's/\.$//' \
  | sort
)"

PUBLIC_NS="$(
  dig +short NS "$BASE_DOMAIN" @1.1.1.1 \
  | sed 's/\.$//' \
  | sort
)"

printf '%s\n' '--- Route 53 assigned NS ---' "$ROUTE53_NS"
printf '%s\n' '--- Public DNS response ---' "$PUBLIC_NS"
diff -u \
  <(printf '%s\n' "$ROUTE53_NS") \
  <(printf '%s\n' "$PUBLIC_NS")
```

`diff`が何も表示せず終了code `0`なら、順序と末尾のドットを正規化したNS集合が一致しています。空、`NXDOMAIN`、不一致の場合は、親Zoneまたはregistrarの設定を修正してDNS伝播を待ちます。組織ネットワークで `1.1.1.1` への直接DNSが禁止されている場合は、組織で許可された外部recursive resolverから同じ確認を行います。

## 6. AWS権限を確認する

AWS credentialにはHosted Zoneの参照だけでなく、OpenShift Installerがクラスター固有レコードを作成・変更・削除する権限も必要です。設定値を読み込んだ状態で、認証検査を再実行します。

```bash
bash scripts/02-check-aws-credentials.sh
```

## 次の章へ進む条件

- `configs/environment` の `BASE_DOMAIN` が所有する実ドメインである。
- `BASE_DOMAIN`に完全一致するPublic Hosted Zoneが1件だけ存在する。
- Route 53割り当てNSと外部DNSから取得したNSが一致する。
- クラスター固有のAPI/Appsレコードをまだ手作業で作成していない。

次: [クライアントツールの確認](05-client-tools.md)
