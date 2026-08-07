# Test entry points

このディレクトリは、配布候補に対する検査の入口を示します。現在の検査実装は
`scripts/`にあり、通常は次を順番に実行します。

```bash
bash scripts/90-static-validation.sh
bash scripts/91-build-release.sh --audit-only
bash scripts/92-test-release-builder.sh
```

AWS上の実機検証は費用と状態変更を伴うため、CIでは実行しません。実機で確認した
範囲と、変更後に再検証が必要な項目は`docs/validation-report.md`を参照してください。
