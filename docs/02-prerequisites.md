# 02. Windows 11 と WSL2 の準備

## この章の目的

Git Bashではなく、Ubuntu on WSL2を構築作業環境として準備します。Git Bashのプロンプトには `MINGW64`、WSL Ubuntuには通常 `user@host:...$` が表示されます。本教材のスクリプトはLinuxコマンドとLinux版OpenShiftバイナリを使うため、Git Bashからは実行できません。

## 1. PowerShellでWSL2を確認する

Windows Terminalの **PowerShell** で実行します。

```powershell
wsl --status
wsl --list --verbose
```

一覧にUbuntuがなく、WSLをまだ導入していない場合は、管理者PowerShellで次を実行してWindowsを再起動します。

```powershell
wsl --install -d Ubuntu
```

Ubuntuの `VERSION` が `1` の場合はWSL2へ変換します。

```powershell
wsl --set-version Ubuntu 2
wsl --set-default-version 2
```

Ubuntuを開始します。

```powershell
wsl -d Ubuntu
```

初回起動ではLinux用ユーザー名とパスワードを作成します。このパスワードは `sudo` で使用し、WindowsやAWSのパスワードとは別物です。

## 2. WSL Ubuntuからリポジトリを開く

以降は **Ubuntuのターミナル** で実行します。まず、次のコード全体を貼り付けます。

```bash
read -r -e -p 'Repository path in WSL: ' REPO_PATH

if [[ ! -d "$REPO_PATH" ]]; then
  echo "ERROR: Directory not found: $REPO_PATH" >&2
elif [[ ! -f "$REPO_PATH/README.md" || \
        ! -d "$REPO_PATH/docs" || \
        ! -d "$REPO_PATH/scripts" ]]; then
  echo "ERROR: Not the openshift-sno repository root: $REPO_PATH" >&2
else
  cd "$REPO_PATH"
  pwd
fi

unset REPO_PATH
uname -s
uname -m
grep -i microsoft /proc/version
```

コードを貼り付けると、最初の行で `Repository path in WSL:` と表示されて入力待ちになります。処理が停止したわけではありません。この表示を確認してから、リポジトリのWSL上の絶対パスを入力し、Enterを押します。

本書の構築例での入力後の画面は、次のようになります。

```text
Repository path in WSL: /mnt/c/Users/Shinesoft/openshift-sno
```

`Repository path in WSL:` は画面に表示されるプロンプトなので入力しません。その後ろへ `/mnt/c/Users/Shinesoft/openshift-sno` を入力してEnterを押します。配布された手順書を別のPCで使用する場合は、`Shinesoft` をそのPCのWindowsユーザー名に置き換えます。一般的な形式は `/mnt/c/Users/<Windowsユーザー名>/openshift-sno` です。すでにプロンプトが `/mnt/c/Users/Shinesoft/openshift-sno$` となっている場合も、上記の絶対パスを入力します。

`Directory not found` が表示された場合や、`pwd` の末尾が `openshift-sno` でない場合は先へ進みません。Windowsの `C:\Users\名前\openshift-sno` は、通常WSLでは `/mnt/c/Users/名前/openshift-sno` になります。

正常例は `Linux`、`x86_64`、Microsoft/WSLを含む文字列です。`MINGW64` が表示される端末へ戻らないでください。

## 3. Linux版クライアントツールを導入する（初回の1回のみ）

プロンプトの現在位置がリポジトリルートであることを確認してから実行します。

```bash
pwd
bash scripts/00-install-client-tools.sh
```

このスクリプトはUbuntuパッケージ、AWS CLI v2 Linux x86_64、OCP 4.21の `oc`、`kubectl`、`openshift-install` を導入します。`sudo` のパスワード入力が発生します。03章と04章でもAWS CLIなどを使用するため、導入作業はこの位置で一度だけ行います。05章では再導入せず、[クライアントツールのバージョンを確認](05-client-tools.md)します。

## 4. AWS、Red Hat、DNSの準備を確認する

- AWSアカウントと専用IAM principal
- `ap-northeast-3` のquota
- Route 53 Public Hosted Zoneと利用するbase domain
- Red Hatアカウントから取得したPull Secret
- 約5 GiB以上のローカル作業領域

SNOノードの公式最小値は8 vCPU / 16 GB RAM / 120 GB storage、本教材の推奨は約32 GiB / gp3 150 GiBです。

## 次の章へ進む条件

Ubuntu内で `aws --version`、`openshift-install version`、`oc version --client` が成功すること。次: [AWSアカウント](03-aws-account-setup.md)
