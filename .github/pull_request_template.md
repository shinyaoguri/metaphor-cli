<!--
タイトルは Conventional Commits で書いてください（squash マージのコミット要約になります）。
例: feat(watch): ...  /  fix(mcp): ...  /  docs: ...
`feat:` → minor / `fix:` `perf:` → patch / その他はリリースなし（AGENTS.md 参照）。
-->

## 目的

<!-- なぜこの変更が要るのか。関連 Issue があれば Closes #123 -->

## 変更点

<!-- 何をどう変えたか。設計判断があればその理由も -->

## 確認方法

<!-- swift test の結果、手で試した手順、実測値など。
     バグ修正なら「失敗する再現テストを先に書いた」ことが分かるように -->

## チェック

- [ ] `swift build` / `swift test` が green
- [ ] テストを追加した（新しいテストは対象の振る舞いを一時的に壊して赤くなるのを確認した）
- [ ] クロスリポ契約（`CONTRACT.md` の環境変数・stdin JSON Lines・Probe ファイル・Syphon pin）に触れる場合、`metaphor` 側の対応 PR / Issue を立て `./scripts/check-contract.sh` が green
- [ ] ドキュメント（README / DEVELOPMENT / CONTRACT）を追随させた
