# 02. Windows 11 と WSL2 の準備

## この章の目的

Git Bash ではなく、Ubuntu on WSL2 を構築作業環境として準備します。Git Bash のプロンプトには `MINGW64`、WSL Ubuntu には通常 `user@host:...$` が表示されます。本教材のスクリプトは Linux コマンドと Linux 版 OpenShift バイナリを使うため、Git Bash からは実行できません。

## 1. PowerShell で WSL2 を確認する

Windows Terminal の **PowerShell** で実行します。

```powershell
wsl --status
wsl --list --verbose
```

一覧に Ubuntu がなく、WSL をまだ導入していない場合は、管理者 PowerShell で次を実行して Windows を再起動します。

```powershell
wsl --install -d Ubuntu
```

Ubuntu の `VERSION` が `1` の場合は WSL2 へ変換します。

```powershell
wsl --set-version Ubuntu 2
wsl --set-default-version 2
```

Ubuntu を開始します。

```powershell
wsl -d Ubuntu
```

初回起動では Linux 用ユーザー名とパスワードを作成します。このパスワードは `sudo` で使用し、Windows や AWS のパスワードとは別物です。

## 2. WSL Ubuntu からリポジトリを開く

以降は **Ubuntu のターミナル**で実行します。

```bash
cd /path/to/openshift-sno
export REPO_ROOT="$PWD"
uname -s
uname -m
grep -i microsoft /proc/version
```

`/path/to/openshift-sno`は、取得したリポジトリの実際のパスへ置き換えます。

正常例は `Linux`、`x86_64`、Microsoft/WSL を含む文字列です。`MINGW64` が表示される端末へ戻らないでください。

## 3. Linux版クライアントツールを導入する

```bash
bash scripts/00-install-client-tools.sh
```

このスクリプトは Ubuntu パッケージ、AWS CLI v2 Linux x86_64、OCP 4.21 の `oc`、`kubectl`、`openshift-install` を導入します。`sudo` のパスワード入力が発生します。詳細は [クライアントツール](05-client-tools.md) を参照してください。

## 4. AWS、Red Hat、DNS の準備を確認する

- AWS アカウントと専用 IAM principal
- `ap-northeast-3` の quota
- Route 53 Public Hosted Zone と利用する base domain
- Red Hat アカウントから取得した Pull Secret
- 約 5 GiB 以上のローカル作業領域

SNO ノードの公式最小値は 8 vCPU / 16 GB RAM / 120 GB storage、本教材の推奨は約 32 GiB / gp3 150 GiB です。

## 次の章へ進む条件

Ubuntu 内で `aws --version`、`openshift-install version`、`oc version --client` が成功すること。次: [AWS アカウント](03-aws-account-setup.md)
