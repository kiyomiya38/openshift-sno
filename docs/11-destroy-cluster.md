# 11. クラスターを安全に削除する

対象名、region、account、install directory、`metadata.json`、必要データの退避、実行中workloadを確認します。残存検査に必要なinfraIDは、destroy前に取得しなければなりません。

次のブロック全体をリポジトリのルートで実行します。サブシェル内で `INFRA_ID` を保持したまま、安全確認付きdestroyと残存検査を順に実行します。

```bash
(
  set -Eeuo pipefail
  source configs/environment

  METADATA_FILE="$INSTALL_DIR/metadata.json"
  [[ -r "$METADATA_FILE" ]] || {
    echo "ERROR: metadata.json is not readable: $METADATA_FILE" >&2
    exit 1
  }

  export INFRA_ID="$(
    jq -er '.infraID | select(type == "string" and length > 0)' \
      "$METADATA_FILE"
  )"
  printf 'Destroy target infraID: %s\n' "$INFRA_ID"

  bash scripts/09-destroy-cluster.sh
  bash scripts/10-check-leftover-resources.sh
)
```

削除スクリプトはaccountをマスク表示し、クラスター名の完全一致入力を要求します。`yes`だけでは消しません。内部では `openshift-install destroy cluster --dir "$INSTALL_DIR" --log-level=info` を実行します。確認ガードを迂回しないため、この内部コマンドを別途直接実行しません。

残存確認対象はNAT Gateway、LB、EBS、EIP、Route 53 record、S3、SG、ENI等です。自動削除失敗時は依存関係（LB/ENI→SG/VPC、NAT→EIP/subnet等）を調べ、infraID/tagが一致する物だけを処理します。アカウント内の無関係資源を名前だけで削除しません。

## Windowsへ登録したラボIngress CAを削除する

[Web Console手順](08-post-install-check.md#21-ラボの既定ingress-caをwindowsで信頼する)でIngress CAを登録した場合だけ、クラスター削除後に **Windows PowerShell** で次を実行します。証明書ファイルからthumbprintを取得し、現在のWindowsユーザーのRoot storeにある完全一致する証明書だけを対象にします。

```powershell
$IngressCaPath = '\\wsl.localhost\Ubuntu\home\hinesoft\.local\share\openshift-sno\certificates\ingress-ca.crt'

if (-not (Test-Path -LiteralPath $IngressCaPath -PathType Leaf)) {
  Write-Output "No saved OpenShift lab Ingress CA was found: $IngressCaPath"
}

if (Test-Path -LiteralPath $IngressCaPath -PathType Leaf) {
  $IngressCa = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $IngressCaPath
  $CertStorePath = "Cert:\CurrentUser\Root\$($IngressCa.Thumbprint)"

  if (-not (Test-Path -LiteralPath $CertStorePath)) {
    Write-Output 'The saved OpenShift lab Ingress CA is not installed.'
  }

  if (Test-Path -LiteralPath $CertStorePath) {
    $Installed = Get-Item -LiteralPath $CertStorePath
    $Installed | Format-List Subject, Issuer, Thumbprint, NotAfter
    $Confirmation = Read-Host 'Type REMOVE-OPENSHIFT-LAB-CA to continue'

    if ($Confirmation -eq 'REMOVE-OPENSHIFT-LAB-CA') {
      Remove-Item -LiteralPath $CertStorePath
      Write-Output 'Removed the OpenShift lab Ingress CA.'
    }

    if ($Confirmation -ne 'REMOVE-OPENSHIFT-LAB-CA') {
      Write-Output 'Certificate removal cancelled.'
    }
  }
}
```

入力待ちでは、表示されたSubject、Issuer、Thumbprintがラボ用証明書であることを確認してから、次を正確に入力します。ほかの証明書を名前だけで削除しません。

```text
Type REMOVE-OPENSHIFT-LAB-CA to continue: REMOVE-OPENSHIFT-LAB-CA
```

削除後、Chromeを終了します。保存した公開証明書ファイルも不要なら、Ubuntuターミナルで次を実行します。このファイルは公開CA証明書であり秘密鍵ではありません。

```bash
rm -f -- "$HOME/.local/share/openshift-sno/certificates/ingress-ca.crt"
```
