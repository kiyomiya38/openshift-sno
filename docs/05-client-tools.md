# 05. クライアントツールの確認

## この章の目的

[前提条件](02-prerequisites.md#3-linux版クライアントツールを導入する初回の1回のみ)で導入したLinux版クライアントツールのアーキテクチャーとバージョンを確認します。03章と04章で既にAWS CLIなどを使用しているため、この章で導入スクリプトを再実行しません。

導入対象はAWS CLI v2、`openshift-install`、`oc`、`kubectl`、`jq`、`curl`、`tar`、`git`、`openssl`、`envsubst`、`dig`、`shellcheck`です。Git BashやWindows側に同名コマンドがあっても使用せず、Ubuntu on WSL2へ導入したLinux x86_64版を使用します。

## 1. 実行環境とバージョンを確認する

Ubuntuのターミナルで、次を実行します。

```bash
uname -m
aws --version
openshift-install version
oc version --client
kubectl version --client
jq --version
git --version
```

期待結果は次のとおりです。

- `uname -m`: `x86_64`
- `aws --version`: `aws-cli/2` で始まる
- `openshift-install version`: `4.21.x`
- `oc version --client`: Client Versionが `4.21.x`
- `kubectl version --client`: エラーなくバージョンが表示される
- `jq --version`: エラーなくバージョンが表示される
- `git --version`: エラーなくバージョンが表示される

AWS CLI v1、Arm64版、またはOpenShift 4.21以外のminor versionが表示された場合は、そのまま進みません。[02章の導入手順](02-prerequisites.md#3-linux版クライアントツールを導入する初回の1回のみ)を見直します。

## 2. 導入元とバージョン方針

`scripts/00-install-client-tools.sh` はAWS公式配布物とRed Hatの `latest-4.21` 公式ミラーからLinux x86_64バイナリを取得し、`/usr/local/bin` へ配置します。`latest-4.21` はpatch releaseに追従するため、上の確認結果を作業記録へ残します。

本書の構築途中ではクライアントツールを更新しません。バージョンを変更する場合は既存クラスターの作業と分離し、利用するOpenShift releaseとの互換性を確認してから、02章の導入手順を最初から実施します。

## 次の章へ進む条件

AWS CLI v2とOpenShift 4.21.xのLinux x86_64版が確認でき、すべてのバージョン確認コマンドが成功すること。

次: [設定](06-install-config.md)
