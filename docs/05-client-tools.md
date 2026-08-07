# 05. クライアントツール

Ubuntu に AWS CLI v2、`openshift-install`、`oc`、`kubectl`、`jq curl tar git openssl gettext-base dnsutils shellcheck` を導入します。Git Bash 側に同名コマンドがあっても利用しません。

自動導入手順は次のとおりです。

```bash
cd /path/to/openshift-sno
export REPO_ROOT="$PWD"
bash scripts/00-install-client-tools.sh
```

スクリプトは AWS 公式配布元と Red Hat の `latest-4.21` 公式ミラーから Linux x86_64 バイナリを取得し、`/usr/local/bin` へ配置します。`latest-4.21` は patch release に追従するため、構築時に実際の出力を記録します。手動ダウンロードする場合は Red Hat Hybrid Cloud Console で Linux/x86_64 と OCP 4.21 を選択します。arm64 版との取り違えに注意してください。

```bash
uname -m
aws --version
openshift-install version
oc version --client
kubectl version --client
jq --version
git --version
```

期待結果は AWS CLI v2 と OpenShift 4.21.x です。異なる OpenShift minor が表示された場合は、そのまま進めません。次: [設定](06-install-config.md)
