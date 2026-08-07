# 04. ドメインと Route 53

ドメインは登録権、Hosted Zone は DNS レコード集合です。Route 53 で取得したドメインは zone が作られます。他社 registrar の場合は Public Hosted Zone を作り、その NS レコード群を registrar 側へ委任します。

`BASE_DOMAIN=example.jp`、`CLUSTER_NAME=ocp-sno` なら、IPI が `api.ocp-sno.example.jp`、内部 API、`*.apps.ocp-sno.example.jp` に必要な record を作ります。base domain の誤りは API/Console/証明書到達性を壊します。

```bash
aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN"
dig NS "$BASE_DOMAIN"
```

AWS credential が Hosted Zone を参照・変更でき、委任先 NS が一致することを確認します。DNS 伝播には時間がかかる場合があります。次: [ツール](05-client-tools.md)

