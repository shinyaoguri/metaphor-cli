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
| 6 | **AI ドキュメント生成物のパス/ファイル名**<br>`llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.{md,json}` | `metaphor` が生成（`make llms-txt` / `make examples-index`、リポジトリにコミット） | `metaphor-cli` の MCP `api_reference` ツール（`MetaphorDocsLocator.swift` / `SketchToolHandler.swift`） |

### `frame.json` スキーマのバージョニング（契約点 4 の補足）

`frame.json` は `schemaVersion`（整数）を持ち、**前方互換の additive 変更**を原則とします。

- **現行 = `schemaVersion: 3`**。トップレベルキー: `schemaVersion` / `id` / `label?` /
  `frame` / `time` / `size{width,height}` / `custom{}` / `customTypes{}` / `warnings[]` / `stats?`。
- `stats`（v2 で追加）= `meanColor[3]` / `meanLuminance` / `contentFraction` /
  `contentBounds?{x,y,width,height}`（正規化・原点左上、blank 時省略） / `sampleGrid`。
- `customTypes`（v3 で追加）= `custom` の各キー → 型タグ（`double` / `int` / `string` /
  `bool` / `vec2` / `vec3` / `vec4`）。ベクトルが裸の配列になるため値だけでは
  `vec2` と「2 要素配列」を区別できない問題を解消する。
- **consumer 規約**: 未知のキーは無視する。`metaphor-cli` の MCP サーバは
  `frame.json` を **verbatim 透過**するため、additive なフィールド追加では cli の
  コード変更は不要（将来 cli が個別フィールドを解釈し始めたら本表に追記する）。
- キーのリネーム／削除／型変更は **破壊的変更**。`schemaVersion` を上げ、両リポジトリの
  本節を同時に更新し、`metaphor-cli` 側に対応 Issue/PR を立てること。

### AI ドキュメント供給（契約点 6 の補足）

`metaphor new` で生成したスケッチは、`metaphor mcp` の `api_reference` ツールを通じて
依存先 metaphor の API ドキュメント（`llms.txt` / `llms-sketch.txt` /
`docs/ai/examples-index.md`）をエージェントへ供給する。`metaphor-cli` 側は
`MetaphorDocsLocator` で docs ルート（path 依存ならローカル checkout、url 依存なら
`.build/checkouts/metaphor`）を解決し、上記ファイル名で読む。

- **soft contract**: 未生成・未解決でも `api_reference` はエラーメッセージで graceful
  degrade する（クラッシュしない）。だが**ファイル名やパスのリネーム/削除**は
  `api_reference` を無言で劣化させるため、契約点として両側を揃える。
- producer（metaphor）側はこれらが**生成・コミット済み**であることが前提。生成器
  （`scripts/generate-llms-txt.py` / `scripts/generate-examples-index.py`）の出力先を
  変えるときは、本表とファイル名を更新し `metaphor-cli` 側に対応 PR/Issue を立てる。

## 変更時のルール（エージェント・人間共通）

上表のトークン（環境変数名・JSON のキー/値・Probe のパスやスキーマ・Syphon の
pin 形式・AI ドキュメントのパス/ファイル名）を変更・追加・削除する場合は、
**必ず以下をワンセットで**行うこと:

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
- `llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.{md,json}` — AI ドキュメント生成物（契約点 6）
- `.github/workflows/release.yml` — Syphon ビルド・Release・cli への dispatch

### metaphor-cli
- `Sources/MetaphorViewer/ViewerWatch.swift` — 子プロセス起動・環境変数設定・stdin 転送
- `Sources/MetaphorViewer/ViewerWindow.swift` — 入力イベントの JSON Lines 送出
- `Sources/MetaphorViewer/SyphonFrameSource.swift` — Syphon 受信
- `Sources/MetaphorCLICore/MCP/MetaphorDocsLocator.swift` / `MCP/SketchToolHandler.swift` — `api_reference`（契約点 6）
- `Package.swift` — Syphon.xcframework の Release pin
- `.github/workflows/syphon-bump.yml` — dispatch 受信で pin を更新する PR を作成
