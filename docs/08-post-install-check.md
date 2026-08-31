# 08. 構築後の確認と Console

## 1. CLIでクラスターを確認する

この章以降で直接実行する `oc` コマンドでも同じkubeconfigを使用できるよう、現在のWSLシェルへ設定します。次のコードを実行したターミナルを継続して使用します。新しいWSLターミナルを開いた場合は、このコードを再実行します。

```bash
source configs/environment
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

if [[ ! -r "$KUBECONFIG" ]]; then
  echo "ERROR: kubeconfig is not readable: $KUBECONFIG" >&2
else
  bash scripts/06-check-cluster.sh
  oc whoami --show-console
fi
```

成功後、`KUBECONFIG` は現在のターミナルに残ります。以降は同じターミナルで、次のような `oc` コマンドを直接実行できます。

```bash
oc get nodes
oc whoami
```

Node=Ready、ClusterVersion=Available、安定後の全OperatorがAvailable=True / Progressing=False / Degraded=Falseなら正常です。直後は一時的Progressingもあるため、events/logと時間経過を確認します。

## 2. Web Consoleへアクセスする

同じWSLターミナルで、Console URLと初期管理者のpasswordファイルを確認します。このコマンドはpassword自体を表示しません。

```bash
CONSOLE_URL="$(oc whoami --show-console)"
KUBEADMIN_PASSWORD_FILE="$INSTALL_DIR/auth/kubeadmin-password"

if [[ -z "$CONSOLE_URL" ]]; then
  echo 'ERROR: Console URL could not be obtained.' >&2
elif [[ ! -r "$KUBEADMIN_PASSWORD_FILE" ]]; then
  echo "ERROR: Password file is not readable: $KUBEADMIN_PASSWORD_FILE" >&2
else
  printf 'Console URL: %s\n' "$CONSOLE_URL"
  printf 'Login user: kubeadmin\n'
  printf 'Password file: %s\n' "$KUBEADMIN_PASSWORD_FILE"
fi
```

### 2.1. ラボの既定Ingress CAをWindowsで信頼する

既定のIngress証明書はIngress Operatorが生成したクラスター内部CAで署名されます。ChromeではOAuth RouteのHSTSにより、`NET::ERR_CERT_AUTHORITY_INVALID` の画面から例外追加できません。`thisisunsafe` や証明書検証を無効にする起動オプションで回避せず、このクラスターが保持する公開Ingress CAだけをWindowsの現在ユーザー信頼ストアへ登録します。

同じWSLターミナルで次を実行します。`router-ca` Secretから公開証明書の `tls.crt` だけを取得し、秘密鍵の `tls.key` は取得・保存しません。保存先はリポジトリ外です。

```bash
(
  set -Eeuo pipefail
  INGRESS_CA_DIR="$HOME/.local/share/openshift-sno/certificates"
  INGRESS_CA_FILE="$INGRESS_CA_DIR/ingress-ca.crt"
  CONSOLE_HOST="${CONSOLE_URL#https://}"
  CONSOLE_HOST="${CONSOLE_HOST%%/*}"

  mkdir -p "$INGRESS_CA_DIR"
  chmod 700 "$INGRESS_CA_DIR"
  umask 077

  oc -n openshift-ingress-operator get secret router-ca \
    -o jsonpath='{.data.tls\.crt}' \
    | base64 --decode >"$INGRESS_CA_FILE"
  [[ -s "$INGRESS_CA_FILE" ]]
  chmod 644 "$INGRESS_CA_FILE"

  openssl x509 -in "$INGRESS_CA_FILE" -noout \
    -subject -issuer -dates -fingerprint -sha256 \
    -ext basicConstraints

  openssl x509 -in "$INGRESS_CA_FILE" -noout \
    -ext basicConstraints \
    | grep -Fq 'CA:TRUE'

  openssl s_client \
    -connect "${CONSOLE_HOST}:443" \
    -servername "$CONSOLE_HOST" \
    -CAfile "$INGRESS_CA_FILE" \
    -verify_return_error </dev/null 2>&1 \
    | grep -F 'Verify return code: 0 (ok)'

  printf 'Windows certificate path: %s\n' \
    "$(wslpath -w "$INGRESS_CA_FILE")"
)
```

`CA:TRUE`、`Verify return code: 0 (ok)`、SHA-256 fingerprint、Windows certificate pathが表示されることを確認します。エラーになった場合や、SubjectとIssuerが異なる場合は証明書を登録しません。

次は **Windows PowerShell** で実行します。本書の構築例のパスを使用しています。直前にWSLが表示したWindows certificate pathと異なる場合は、`$IngressCaPath` だけを実際の値へ置き換えます。登録先はPC全体ではなく、現在のWindowsユーザーの `Trusted Root Certification Authorities` です。

```powershell
$IngressCaPath = '\\wsl.localhost\Ubuntu\home\hinesoft\.local\share\openshift-sno\certificates\ingress-ca.crt'

if (-not (Test-Path -LiteralPath $IngressCaPath -PathType Leaf)) {
  throw "Ingress CA certificate was not found: $IngressCaPath"
}

$IngressCa = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $IngressCaPath

$IngressCa | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter

$Confirmation = Read-Host 'Type TRUST-OPENSHIFT-LAB-CA to continue'
$CertStorePath = "Cert:\CurrentUser\Root\$($IngressCa.Thumbprint)"

if ($Confirmation -ne 'TRUST-OPENSHIFT-LAB-CA') {
  Write-Output 'Certificate import cancelled.'
}

if ($Confirmation -eq 'TRUST-OPENSHIFT-LAB-CA') {
  if (Test-Path -LiteralPath $CertStorePath) {
    Write-Output 'The OpenShift lab Ingress CA is already trusted.'
  }

  if (-not (Test-Path -LiteralPath $CertStorePath)) {
    Import-Certificate -FilePath $IngressCaPath -CertStoreLocation 'Cert:\CurrentUser\Root'
  }
}
```

次の入力待ちでは、文字列を正確に入力してEnterを押します。

```text
Type TRUST-OPENSHIFT-LAB-CA to continue: TRUST-OPENSHIFT-LAB-CA
```

証明書登録後はChromeのすべてのウィンドウを終了して再起動します。`Console URL` を再度開き、OAuth画面まで証明書警告なしで表示されることを確認します。警告が残る場合は続行せず、Chromeの再起動、登録先、証明書期限、URLのホスト名を確認します。

### 2.2. kubeadminでログインする

表示された `Console URL` をWindowsのMicrosoft EdgeまたはGoogle Chromeで開きます。URLは本書の構築例では `https://console-openshift-console.apps.ocp-sno.lab.k8study.com` の形式になりますが、固定値を入力せず、コマンドが返したURLを使用します。

ブラウザーのログイン画面を開いてから、同じWSLターミナルで次のコマンドを実行し、初期passwordを表示します。この出力は秘密情報です。画面共有、操作ログ、チャット、Issue、Gitへ残さず、ブラウザーにも保存しません。

```bash
cat "$KUBEADMIN_PASSWORD_FILE"
```

ログイン画面へ次を入力します。

```text
Username: kubeadmin
Password: 上のコマンドで表示された文字列
```

ログイン後、`Home` → `Overview` でクラスターの状態を確認し、`Compute` → `Nodes` でSNOノードが `Ready` であることを確認します。

初期 `kubeadmin` は強い管理権限を持ちます。学習後もクラスターを維持する場合はIdentity Providerと通常の管理者を設定し、別の `cluster-admin` でログインできることを確認してから `kubeadmin` の廃止を検討します。

本番環境ではクライアントごとに内部CAを手動登録せず、組織またはpublic CAが発行した `*.apps.<cluster>.<baseDomain>` 証明書へ置き換えます。Consoleへ接続できない場合は、`dig`、Route 53、証明書時刻、Ingress Pod/Operator、LB target/SGを順に確認します。公式手順は[OpenShift Container Platform 4.21: Accessing the web console](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/web_console/web-console)と[Replacing the default ingress certificate](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/configuring-certificates#replacing-default-ingress)を参照してください。

次: [サンプル](09-deploy-sample-app.md)
