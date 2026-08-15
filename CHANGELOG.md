# Changelog

`metaphor-cli` の変更履歴。書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、
バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

各版のコミット単位の一覧は [Releases](https://github.com/shinyaoguri/metaphor-cli/releases)
が自動生成しています。このファイルは**利用者に見える変化**だけを人手で要約したものです。

## [Unreleased]

### 追加

- `metaphor version` が**環境の版一覧**になった。CLI 本体に加えて、いるディレクトリで
  解決されている `metaphor` ライブラリの版も出す（ネットワークは叩かない。最新かどうかは
  従来どおり `metaphor update check` の担当）
  - CLI 行が `metaphor …` から `metaphor-cli …` になり、ライブラリ版との取り違えが消えた
  - ライブラリ行は `0.9.0 (Package.resolved)` / `local path ../metaphor` /
    未解決（スケッチ外）の 3 通り
  - `metaphor version --json` を追加。CI・AI エージェント向けにキーが常にそろった
    JSON を出す（当てはまらない値は `null`）
  - `metaphor doctor` も冒頭で同じ 2 行を出す
- `watch` のリロードで**子スケッチの状態を運ぶ**（契約点 8）。再ビルド後に子を
  作り直す前へ保存要求を挟み、書き上がった `state.json` を次の子へ
  `METAPHOR_RESTORE_STATE` で渡す
  - スケッチ側が `saveState()` / `restoreState(_:)` を実装していれば
    シミュレーションの状態が、`SketchConfig(preserveClock: true)` なら
    `frameCount` / `time` が編集をまたいで続く（metaphor v0.9 以降）
  - 保存の待ち時間は最大 250ms で、応答が無ければ状態なしでリロードを進める。
    一度も応答が無かったセッションでは以降の要求自体を止めるため、状態保持を
    使っていないスケッチのリロードは従来どおりの速さのまま
- MCP に `params` / `set_param` ツールを追加。スケッチが `@Param` で宣言した値を
  AI エージェントが一覧し、**再ビルドなしで**（ファイル往復 1 フレームで）書き換えられる
  - 人間の GUI スライダーと同一のストアを操作する（競合は last-writer-wins）。
    stdin を経由しないため、`metaphor watch` にアタッチした共有セッションでも使える
    （`input` は単独モード限定のまま）
  - 拒否（未知の名前・型不一致・`choices` 外）は理由つきでエラーとして返る。
    数値は宣言された `min` / `max` へクランプされる

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

[Unreleased]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/shinyaoguri/metaphor-cli/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shinyaoguri/metaphor-cli/releases/tag/v0.1.0
