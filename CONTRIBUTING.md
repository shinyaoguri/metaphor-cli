# Contributing

`metaphor-cli` への貢献は歓迎します。バグ報告・提案だけでも十分ありがたいので、
まずは気軽に [Issues](https://github.com/shinyaoguri/metaphor-cli/issues) へどうぞ。

このファイルは「変更を送るまでの流れ」だけを扱います。中身の設計・実装手順は
[DEVELOPMENT.md](DEVELOPMENT.md)、CLI の使い方は [README.md](README.md) が正本です。

## どこに報告するか

| 事象 | リポジトリ |
| --- | --- |
| `metaphor` コマンドの挙動・テンプレート・MCP サーバ | このリポジトリ |
| 描画結果・`Sketch` API・シェーダなどライブラリ側 | [shinyaoguri/metaphor](https://github.com/shinyaoguri/metaphor) |
| 両方に跨るもの（`CONTRACT.md` / Probe wire format / `METAPHOR_*` 環境変数） | 両方に立てて相互リンク |

迷ったらこちらに立ててもらえれば振り分けます。バグ報告には `metaphor doctor` の出力を
添えてください（環境情報がまとまっています）。

## 開発環境

- Apple Silicon Mac / macOS 14+、Xcode 15+ / Swift 5.10+
- 外部依存は Syphon.xcframework のみ（`Package.swift` が GitHub Release から checksum 付きで取得）

```bash
swift build                   # ビルド
swift test                    # テスト
swift run metaphor --help     # ローカルビルドを直接実行
make install                  # release ビルドを ~/.local へ導入（Syphon.framework 同梱）
make doctor                   # 環境診断
./scripts/check-contract.sh   # metaphor ⇄ metaphor-cli 契約チェック
```

## ブランチと PR

GitHub Flow です。`main` が唯一の長命ブランチで、直 push はできません
（PR 必須 / `build-and-test` 必須 / squash マージのみ / 署名必須）。

1. `main` から `<type>/<短い説明>` のブランチを切る
2. 小さく作って早めに PR を出す（未完成なら Draft で構いません）
3. `build-and-test` が green になったらマージ

**PR タイトルは Conventional Commits で書いてください。** squash マージのコミット要約に
そのまま使われ、リリースの bump 判定にも使われます。

```
<type>(<scope>): <要約>
```

type は `feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `ci` / `perf`。
PR 本文には目的・変更点・確認方法を書きます（テンプレートが用意されています）。

## テスト

テストは実装と同じ PR に含めます。

- バグ修正は、まず失敗する再現テストを書く
- 正常系に加えて失敗系・境界値を最低ひとつ
- 新しいテストは、検証対象の振る舞いを一時的に壊して赤くなるのを確認してから仕上げる
  （壊しても緑のままのテストは書き直す）

モックの土台は `Sources/MetaphorCLICore/Support.swift` にあります。詳細は
[DEVELOPMENT.md](DEVELOPMENT.md) の "Test Infrastructure" を参照してください。

## クロスリポ契約に触れるとき

環境変数 `METAPHOR_VIEWER` / `METAPHOR_SYPHON_NAME`、stdin へ送る JSON Lines 入力イベント、
Probe ファイル、Syphon.xcframework の pin は `metaphor` 本体との**暗黙の契約**です。
ここに触れる変更は `metaphor-cli` 単体では完結しません。

- `metaphor` 側も同時に更新し、両リポの [CONTRACT.md](CONTRACT.md) を揃える
- `./scripts/check-contract.sh` が green であることを確認する
- 片方だけ作業中なら、もう片方に対応 PR / Issue を必ず立てる

## リリース

PR のマージだけで自動的に走ります。`release-on-merge.yml` が PR タイトル（= squash コミット）
から bump を判定します。

- `feat:` → minor / `fix:` `perf:` → patch / その他（docs・chore・refactor・test・ci）→ リリースなし
- 明示したいときは `release:major` / `release:minor` / `release:patch` ラベル
- 抑止したいときは `release:skip` ラベル
- **major は自動判定しません**（`!` 付きタイトルでも type どおりの bump）

詳細は [AGENTS.md](AGENTS.md) と [docs/homebrew.md](docs/homebrew.md) を参照してください。

## AI エージェントで作業する場合

起点は [AGENTS.md](AGENTS.md) です（Claude Code は [CLAUDE.md](CLAUDE.md) 経由で読み込みます）。

## ライセンス

貢献物は [MIT License](LICENSE) の下で公開されます。
