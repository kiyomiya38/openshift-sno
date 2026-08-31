# 配布物の監査と作成

## この文書の目的

この文書はラボ利用者の構築手順ではなく、配布担当者向けの保守手順です。AWSとローカル資材の完全削除を[08. 完全削除](08-destroy.md)で検証した後にだけ使用します。

## 1. 静的検査と非破壊auditを実行する

作業ディレクトリを直接ZIP化しません。ローカルcleanup後、静的検査とrelease builderのself-testを順番に実行します。

```bash
cd "$LAB_ROOT"
bash scripts/91-static-validation.sh
```

```bash
bash scripts/92-test-release-builder.sh
```

```bash
bash scripts/93-build-release.sh --audit-only
```

`scripts/92-test-release-builder.sh`は一時fixture上でrelease builderを2回実行し、archiveの再現性、checksum、禁止ファイルと秘密鍵fixtureの拒否を検査します。source treeやAWSは変更しません。auditはstate、Plan、logs、secret、private key、kubeconfig、Ignition、個人パス、具体的なAccount IDを検出した場合に失敗します。値は表示せず、問題のファイル名だけを報告します。

## 2. 配布archiveを作成する

配布archiveは`upi-lab`外の新規出力ディレクトリへ作成します。

```bash
mkdir -p "$HOME/openshift-upi-lab-release"
bash scripts/93-build-release.sh "$HOME/openshift-upi-lab-release"
```

スクリプトはsource treeを変更せず、許可リスト対象だけをstageし、`openshift-upi-lab-source.tar.gz`とSHA-256ファイルを作成します。既存archiveを上書きしません。配布前にchecksumを検証し、archiveを展開してREADME、LICENSE、SECURITY、第三者noticeが含まれることを確認します。

## 3. 完了条件

- 静的検査、release builder self-test、audit-onlyがすべて合格。
- 配布物にstate、Plan、provider cache、ログ、secret、kubeconfig、Ignitionが含まれない。
- checksumを検証済み。
- クリーンなrelease archiveだけを配布する。
