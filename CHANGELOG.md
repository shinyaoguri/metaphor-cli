# Changelog

**`metaphor-cli` の変更履歴の正本は
[Releases](https://github.com/shinyaoguri/metaphor-cli/releases) です。**
このファイルは正本へのポインタと、v0.5.1 までの手書き要約のアーカイブで、**以降は追記しません**。

```bash
gh release list          # 版の一覧
gh release view          # 最新版の変更点（<tag> を渡せばその版）
```

版と版の差分は
`https://github.com/shinyaoguri/metaphor-cli/compare/<古い tag>...<新しい tag>`
の形で引けます。

## なぜ人手の CHANGELOG をやめたか

本リポジトリは **PR のマージだけでリリースが走ります**（`.github/workflows/release-on-merge.yml`）。
人間が「これからリリースする」と意識する瞬間が無いため、[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)
の `Unreleased` → 版節という**昇格工程を挿す場所がありません**。

実際、追記そのものは行われていたのに昇格だけが落ち、最後の版節が `0.5.1` のまま
**10 版ぶん**放置されました。出荷済みの機能が `Unreleased`（= 未リリース）に見えるせいで、
「この MCP ツールはリリース版で使えるのか」に答えられず `git tag --contains` を引く、
という実害も出ています。「CHANGELOG があるのに古い」は「CHANGELOG が無い」より悪いので、
二重管理をやめて Releases に一本化しました
（[#97](https://github.com/shinyaoguri/metaphor-cli/issues/97)）。

CI がこの方針を機械的に守ります（`.github/workflows/ci.yml` の
"Check CHANGELOG stays a pointer"）。版節や `Unreleased` を書き戻すと落ちます。

## アーカイブ — v0.5.1 まで（手書き要約。以降は追記しない）

バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。
**v0.6.0 以降はここに現れません**（Releases を参照）。

## [0.5.1] - 2026-08-01

### 改善

- `watch` の編集→反映（roundtrip）を p50 2.8s → 1.2s へ短縮
  - バイナリ解決に executable target フォールバックを追加。`products` 宣言を持たない
    パッケージ（example・テンプレートの標準形）で解決が毎回失敗し、`swift run` 経由の
    起動にフォールバックしていた
  - 変更検知を FSEvents 化（従来はポーリング 0.4s）。FSEvents が届かないボリューム向けに
    低頻度の安全ポーリングを併走
- `build_status` に detect / build / relaunch の分解計時を記録

## [0.5.0] - 2026-07-20

### 追加

- `run` / `watch` に `--metrics` — fps・メモリ・CPU 等をターミナルへライブ表示
- MCP: `frame.json` の `performance` セクションに対応（schema 同期・ツール説明・docs）

### 変更

- ステータスラインから frame time を削除（fps があれば十分）
- リリースを PR タイトル（Conventional Commits）からの自動 bump 判定に変更。
  マージだけでリリースが走る

## [0.4.0] - 2026-07-18

### 追加

- 新バージョンを非侵襲に通知する update notifier

### 修正

- テンプレート探索順を、実行バイナリ隣接の `share` を優先するよう変更し、使用中の root を表示
- 生成プロジェクトの `.gitignore` に `.metaphor/`（Probe 出力）を追加
- 契約チェックの `fetch_remote` にリトライを追加

## [0.3.0] - 2026-07-03

### 追加

- `metaphor new` の生成プロジェクトに Claude Code 向け `CLAUDE.md` ブリッジを同梱

### 修正

- MCP: `request.json` を `rename(2)` でアトミックに書き、失敗応答を warnings 付きエラーで返す

## [0.2.0] - 2026-07-01

### 追加

- `metaphor mcp` — AI エージェント向けローカル MCP サーバ（`snapshot` / `input` /
  `build_status` / `capture_sequence`）
- 共有セッション — 起動中の `watch` に `mcp` をアタッチし、人間と AI が同じスケッチを観測
- `metaphor watch` — ソース変更を監視して再ビルド・差し替え。Syphon 経由のライブビューア窓を
  既定で常設（`--no-viewer` で無効化、`--syphon-name` で名前を固定）
- ライブビューアがマウス・キーボード入力をスケッチへ転送
- `run --syphon` と安定した MCP Syphon 名
- `metaphor new` の in-place 初期化と、AI 支援を前提にしたプロジェクト生成
- `doctor` が Syphon.framework の読み込み元を報告
- metaphor ⇄ metaphor-cli のクロスリポ契約ガードレールと wire schema 正典

### 修正

- ビューアの黒画面・リロード後のフレーム凍結・入力によるフリーズを解消
- すべてのインストール経路で Syphon.framework を同梱

## [0.1.1] - 2026-05-08

### 追加

- Homebrew tap への Formula 自動公開

## [0.1.0] - 2026-05-08

### 追加

- 初回リリース。`new` によるテンプレートからのプロジェクト生成、`run`、`update`、
  Homebrew 対応のリリースフロー

[0.5.1]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shinyaoguri/metaphor-cli/releases/tag/v0.1.0
