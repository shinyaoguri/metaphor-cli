# CONTRACT.md — metaphor ⇄ metaphor-cli の連携契約

> **このファイルは両リポジトリ（`metaphor` と `metaphor-cli`）に同一内容で置かれます。**
> 片方を変更したら、もう片方の `CONTRACT.md` も同じ内容に更新してください。

`metaphor`（Swift ライブラリ／スケッチ実行体）と `metaphor-cli`（`metaphor`
コマンド・ライブビューア）は **別リポジトリ・別 SwiftPM パッケージ**です。
`metaphor-cli` は `metaphor` を Swift ライブラリとして依存しておらず、両者は
以下の **暗黙の契約（ランタイム / バイナリ）** だけで結合しています。

この契約のどれかを片方だけで変更すると、ライブビューア連携が**無言で壊れます**。
変更時は必ず両側を揃えてください（下記「変更時のルール」）。

## 契約点

| # | 契約 | producer（定義側） | consumer（依存側） |
|---|---|---|---|
| 1 | **Syphon.xcframework の Release pin**<br>URL `…/releases/download/<tag>/Syphon.xcframework.zip` + SHA256 checksum | `metaphor` が Release で発行（`release.yml`） | `metaphor-cli/Package.swift` の `binaryTarget` |
| 2 | **環境変数**<br>`METAPHOR_VIEWER` / `METAPHOR_SYPHON_NAME` / `METAPHOR_FPS` / `METAPHOR_PROBE` | `metaphor` が読む（`SketchRunner.swift`） | `metaphor-cli` が設定（`ViewerWatch.swift` / `Watch.swift`） |
| 3 | **stdin 入力イベント（JSON Lines）**<br>キー `t` の値 `mouseDown` `mouseUp` `mouseMove` `mouseDrag` `scroll` `keyDown` `keyUp`、フィールド `x` `y` `button` `code` `chars` `repeat` `dx` `dy` | `metaphor` が解析（`InputInjectionPlugin.swift`） | `metaphor-cli` が送出（`ViewerWindow.swift`） |
| 4 | **Probe ファイル契約**<br>`.metaphor/probe/request.json`（リクエスト）/ `.metaphor/probe/current/frame.{png,json}`（出力）と `frame.json` スキーマ | `metaphor`（`MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift`） | AI エージェント・ツール（必要なら `metaphor-cli`） |
| 5 | **Syphon サーバー名 / headless 挙動**<br>`METAPHOR_VIEWER=1` で `METAPHOR_SYPHON_NAME` のサーバーへ publish | `metaphor` headless モード（`SketchRunner.swift`） | `metaphor-cli`（`SyphonFrameSource.swift`） |

## 変更時のルール（エージェント・人間共通）

上表のトークン（環境変数名・JSON のキー/値・Probe のパスやスキーマ・Syphon の
pin 形式）を変更・追加・削除する場合は、**必ず以下をワンセットで**行うこと:

1. **producer 側**と**consumer 側の両リポジトリ**を同時に更新する。
2. **両リポジトリの `CONTRACT.md`** を同じ内容に更新する。
3. ローカルで `./scripts/check-contract.sh` を実行して緑であることを確認する。

> 片方のリポジトリだけで作業している場合でも、契約に触れたら**もう片方の
> リポジトリに必ず対応 PR / Issue を立てる**こと。「あとで」は忘れます。

## 自動チェック

- **契約ドリフト検知（L2b）**: 両リポジトリの CI が `scripts/check-contract.sh`
  を実行し、合意済みトークンが期待ファイルから消えていれば落とします
  （リネーム・削除の検出）。
- **Syphon pin 自動 bump（L2a）**: `metaphor` の安定版 Release 時に
  `repository_dispatch`（`event_type: syphon-release`）で `metaphor-cli` へ
  通知し、`metaphor-cli` 側のワークフローが `Package.swift` の URL + checksum を
  更新する PR を自動作成します。

## 関連ファイル

### metaphor
- `Sources/MetaphorCore/Sketch/SketchRunner.swift` — 環境変数読み取り・headless
- `Sources/MetaphorCore/Input/InputInjectionPlugin.swift` — stdin JSON Lines 解析
- `Sources/MetaphorCore/Probe/MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift` — Probe 契約
- `.github/workflows/release.yml` — Syphon ビルド・Release・cli への dispatch

### metaphor-cli
- `Sources/MetaphorViewer/ViewerWatch.swift` — 子プロセス起動・環境変数設定・stdin 転送
- `Sources/MetaphorViewer/ViewerWindow.swift` — 入力イベントの JSON Lines 送出
- `Sources/MetaphorViewer/SyphonFrameSource.swift` — Syphon 受信
- `Package.swift` — Syphon.xcframework の Release pin
- `.github/workflows/syphon-bump.yml` — dispatch 受信で pin を更新する PR を作成
