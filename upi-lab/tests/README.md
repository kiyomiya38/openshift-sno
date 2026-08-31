# Test entry points

このディレクトリは、配布候補に対する検査の入口を示します。現在の検査実装は
`scripts/`にあり、通常は次を順番に実行します。

```bash
bash scripts/91-static-validation.sh
bash scripts/92-test-release-builder.sh
bash scripts/93-build-release.sh --audit-only
```

`91-static-validation.sh`には、初回`terraform init`直後のstate未作成状態を
managed resource 0件として安全に扱う回帰テストも含まれます。Terraformの実stateや
AWS APIは使用しません。

隔離済みローカルアーカイブについても、危険なIDと誤確認を拒否し、PKI追加後に指定した
1アーカイブだけを削除して、隣接アーカイブと保持資材を変更しないことを一時HOME内で検証します。

AWS上の実機検証は費用と状態変更を伴うため、CIでは実行しません。実機で確認した
範囲と、変更後に再検証が必要な項目は`docs/validation-report.md`を参照してください。
