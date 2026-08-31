# 06. install-config.yaml

## この章の目的

Pull Secretと専用SSH公開鍵をリポジトリ外へ安全に用意し、全前提条件を検査してから `install-config.yaml` を生成します。

## 1. Pull Secretを保存する

Red Hatアカウントで[Red Hat Hybrid Cloud Console: Pull Secret](https://console.redhat.com/openshift/install/pull-secret)を開き、Pull Secretを取得します。内容はcredentialであるため、チャット、Git、Issue、画面共有へ貼り付けません。

WSL側で保存先を作成し、取得したJSONを `~/.secrets/pull-secret.txt` へ保存します。次は `vi` を使う例です。別のエディターを使っても構いません。

```bash
mkdir -p "$HOME/.secrets"
chmod 700 "$HOME/.secrets"
vi "$HOME/.secrets/pull-secret.txt"
```

保存後は、内容そのものを出力せずにpermissionとJSON構文を検査します。

```bash
chmod 600 "$HOME/.secrets/pull-secret.txt"
jq -e 'type == "object" and length > 0' \
  "$HOME/.secrets/pull-secret.txt" >/dev/null
echo 'Pull Secret JSON validation PASSED.'
```

## 2. 専用SSH鍵を作成する

既存の既定SSH鍵を流用せず、このラボ専用の鍵を作成します。本教材では空のパスフレーズを使用しません。パスワード管理ツールで、この鍵専用の16文字以上のランダムなパスフレーズを生成して保存します。AWS、Red Hat、Windows、Linuxユーザーなど、ほかのパスワードを再利用しません。

次のコード全体を貼り付けて実行します。同名の鍵があれば上書きせず、既存鍵を検査します。パスフレーズを `ssh-keygen -N` のコマンド引数、`configs/environment`、シェル履歴、Git、チャットへ記載しません。

```bash
(
  set -Eeuo pipefail
  SSH_KEY="$HOME/.ssh/openshift_sno"

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [[ -e "$SSH_KEY" || -e "$SSH_KEY.pub" ]]; then
    [[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]] || {
      echo 'ERROR: The SSH private/public key pair is incomplete.' >&2
      exit 1
    }
    echo 'Existing dedicated SSH key was retained.'
  else
    ssh-keygen -t ed25519 \
      -f "$SSH_KEY" \
      -C 'openshift-sno'
  fi

  chmod 600 "$SSH_KEY"
  chmod 644 "$SSH_KEY.pub"
  ssh-keygen -lf "$SSH_KEY.pub"

  if ssh-keygen -y -P '' -f "$SSH_KEY" >/dev/null 2>&1; then
    echo 'ERROR: The SSH private key accepts an empty passphrase.' >&2
    exit 1
  fi

  echo 'Enter the SSH key passphrase once more for validation.'
  DERIVED_PUBLIC="$(
    ssh-keygen -y -f "$SSH_KEY" \
    | awk 'NR == 1 { print $1 " " $2 }'
  )"
  SAVED_PUBLIC="$(awk 'NR == 1 { print $1 " " $2 }' "$SSH_KEY.pub")"
  [[ "$DERIVED_PUBLIC" == "$SAVED_PUBLIC" ]] || {
    echo 'ERROR: The SSH private key and public key do not match.' >&2
    exit 1
  }
  echo 'SSH key pair and passphrase validation PASSED.'
)
```

コードを実行すると、新しい鍵を作成する場合は次の入力待ちになります。事前に生成した16文字以上の専用パスフレーズを入力してEnterを押し、確認のため同じパスフレーズをもう一度入力してEnterを押します。入力中は画面に文字が表示されませんが正常です。

```text
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
```

鍵の作成後、または既存鍵を検査する場合は、続いて次の入力待ちになります。同じパスフレーズをもう一度入力してEnterを押します。

```text
Enter the SSH key passphrase once more for validation.
Enter passphrase:
```

最後に `SSH key pair and passphrase validation PASSED.` が表示されることを確認します。新規作成時は同じパスフレーズを合計3回、既存鍵の検査時は1回入力します。

空パスフレーズで作成して検査が失敗した場合は、次でパスフレーズを追加します。現在のパスフレーズでは何も入力せずEnterを押し、その後に16文字以上の新しいパスフレーズを2回入力します。完了後、上の検査ブロックを再実行します。

```bash
ssh-keygen -p -f "$HOME/.ssh/openshift_sno"
```

秘密鍵とパスフレーズは共有せず、`configs/environment` には公開鍵の `.pub` ファイルだけを指定します。OpenShift Installerは公開鍵を使用するため、秘密鍵にパスフレーズを設定しても構築処理には影響しません。将来この鍵でSSH接続するときにパスフレーズを入力します。

## 3. 設定値と全前提条件を確認する

`configs/environment` の次の値を実際の保存先と希望するEC2構成に合わせます。

```bash
export CONTROL_PLANE_INSTANCE_TYPE="m6i.2xlarge"
export CONTROL_PLANE_VOLUME_SIZE="150"
export PULL_SECRET_FILE="${HOME}/.secrets/pull-secret.txt"
export SSH_PUBLIC_KEY_FILE="${HOME}/.ssh/openshift_sno.pub"
```

保存後、統合preflightを実行します。この検査は秘密値そのものを表示しません。

```bash
(
  set -Eeuo pipefail
  source configs/environment
  bash scripts/01-check-prerequisites.sh
)
```

検査が失敗した場合は、該当項目を修正して再実行します。すべて成功するまで `install-config.yaml` を生成しません。

## 4. install-config.yamlを生成する

`compute.replicas: 0` と `controlPlane.replicas: 1` がSNOを成立させ、masterをschedulableにします。`OVNKubernetes` はSNOで必須です。`platform.aws.region` は大阪、`publish: External` はpublic cluster、control-plane type/rootVolumeはEC2/EBS仕様です。

次のブロックをリポジトリのルートで実行します。サブシェル内で設定を読み込むため、別のターミナルから再開した場合でも `$INSTALL_DIR` が空のまま展開されません。

```bash
(
  set -Eeuo pipefail
  source configs/environment
  bash scripts/04-create-install-config.sh
  chmod 600 \
    "$INSTALL_DIR/install-config.yaml" \
    "$INSTALL_DIR/install-config.yaml.backup"
)
```

インストーラーは作成中に `install-config.yaml` を消費するため、スクリプトはbackupを作ります。両方にPull SecretとSSH公開鍵が含まれ、Git管理・共有は禁止です。テンプレートは `envsubst` し、秘密値はファイルから読みます。

```bash
openshift-install explain installconfig
```

対象版で正式なfieldだけを使うため、必要なら上記schemaとRed Hat 4.21 AWS customizationを照合します。

## 次の章へ進む条件

- `scripts/01-check-prerequisites.sh` が成功した。
- `install-config.yaml` とbackupが `INSTALL_DIR` にあり、permissionが `600` である。
- ファイルをGitへ追加していない。

次: [インストール](07-installation.md)
