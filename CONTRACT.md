# CONTRACT.md — metaphor ⇄ metaphor-cli の連携契約

> **このファイルは両リポジトリ（`metaphor` と `metaphor-cli`）に同一内容で置かれます。**
> 片方を変更したら、もう片方の `CONTRACT.md` も同じ内容に更新してください。

`metaphor`（Swift ライブラリ／スケッチ実行体）と `metaphor-cli`（`metaphor`
コマンド・ライブビューア）は **別リポジトリ・別 SwiftPM パッケージ**です。
`metaphor-cli` は `metaphor` を Swift ライブラリとして依存しておらず、両者は
以下の **暗黙の契約（ランタイム / バイナリ）** だけで結合しています。

この契約のどれかを片方だけで変更すると、ライブビューア連携が**無言で壊れます**。
変更時は必ず両側を揃えてください（下記「変更時のルール」）。

## リポジトリの役割

- **metaphor**（Swift ライブラリ／スケッチ実行体）: クリエイティブコーディングの
  ランタイム。描画に加えて、**自身を観測・操作可能にするプリミティブ**——Probe
  （`.metaphor/probe` 経由でフレーム＋内部状態を書き出す）、stdin JSON Lines の
  入力注入、Syphon publish——と、**AI 向けの静的ドキュメント**（`llms.txt` /
  `llms-sketch.txt` / `docs/ai/`）を提供する。下表の **producer（定義側）**。
- **metaphor-cli**（`metaphor` コマンド／ライブビューア）: それらを束ねる開発ツール。
  スキャフォールド・watch・ライブビューアに加え、ライブラリの観測／操作能力を
  **MCP サーバ**（`snapshot` / `capture_sequence` / `input` / `build_status` / `api_reference`）
  として AI エージェントへ露出する。下表の **consumer（依存側）**。

> **「AI と協調する」機能は、どちらか一方ではなく両者の分担で成り立つ。** 観測・操作・
> 静的ドキュメントという *能力* は `metaphor` が所有し、`metaphor-cli` はそれを MCP という
> 標準プロトコルでエージェントに使わせ、ビルド競合の起きない単一セッションに束ねる *窓口*
> を担う。原理上は cli 無しでも、`METAPHOR_PROBE=1` で起動したスケッチに対して
> `.metaphor/probe/request.json` を書き、stdin に入力イベントを流せば観測・操作は成立する
> （どちらもライブラリ機能）。MCP サーバ自体は metaphor-cli にしか無い。

## 契約点

| # | 契約 | producer（定義側） | consumer（依存側） |
|---|---|---|---|
| 1 | **Syphon.xcframework の Release pin**<br>URL `…/releases/download/<tag>/Syphon.xcframework.zip` + SHA256 checksum | `metaphor` が Release で発行（`release.yml`） | `metaphor-cli/Package.swift` の `binaryTarget` |
| 2 | **環境変数**<br>`METAPHOR_VIEWER` / `METAPHOR_SYPHON_NAME` / `METAPHOR_FPS` / `METAPHOR_PROBE` / `METAPHOR_SOURCE_STAMP` | `metaphor` が読む（`SketchRunner.swift`、`METAPHOR_SOURCE_STAMP` は `MetaphorProbePlugin.swift`） | `metaphor-cli` が設定（`ViewerWatch.swift` / `Watch.swift`） |
| 3 | **stdin 入力イベント（JSON Lines）**<br>キー `t` の値 `mouseDown` `mouseUp` `mouseMove` `mouseDrag` `scroll` `keyDown` `keyUp`、フィールド `x` `y` `button` `code` `chars` `repeat` `dx` `dy` | `metaphor` が解析（`InputInjectionPlugin.swift`） | `metaphor-cli` が送出（`ViewerWindow.swift`） |
| 4 | **Probe ファイル契約**<br>`.metaphor/probe/request.json`（リクエスト）/ `.metaphor/probe/current/frame.{png,json}`（単一フレーム出力）/ `.metaphor/probe/current/sequence/`（連続フレーム出力）と `frame.json` / `sequence.json` スキーマ、`ProbeRequest` のフィールド（`id` / `label` / `scale` / `frames` / `every`） | `metaphor`（`MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift` / `ProbeSequenceManifest.swift` / `ProbeRequest.swift`） | AI エージェント・ツール（`metaphor-cli` の `snapshot` / `capture_sequence`） |
| 5 | **Syphon サーバー名 / headless 挙動**<br>`METAPHOR_VIEWER=1` で `METAPHOR_SYPHON_NAME` のサーバーへ publish | `metaphor` headless モード（`SketchRunner.swift`） | `metaphor-cli`（`SyphonFrameSource.swift`） |
| 6 | **AI ドキュメントのパス/ファイル名**<br>`llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.{md,json}` | `metaphor` が用意（`llms.txt` / `examples-index` は生成物＝`make llms-txt` / `make examples-index`、`llms-sketch.txt` は**手書き**。いずれもリポジトリにコミット） | `metaphor-cli` の MCP `api_reference` ツール（`MetaphorDocsLocator.swift` / `SketchToolHandler.swift`） |

### `frame.json` スキーマのバージョニング（契約点 4 の補足）

`frame.json` は `schemaVersion`（整数）を持ち、**前方互換の additive 変更**を原則とします。

- **現行 = `schemaVersion: 4`**。トップレベルキー: `schemaVersion` / `id` / `label?` /
  `sourceStamp?` / `frame` / `time` / `size{width,height}` / `custom{}` / `customTypes{}` /
  `warnings[]` / `stats?`。
- `stats`（v2 で追加）= `meanColor[3]` / `meanLuminance` / `contentFraction` /
  `contentBounds?{x,y,width,height}`（正規化・原点左上、blank 時省略） / `sampleGrid`。
- `customTypes`（v3 で追加）= `custom` の各キー → 型タグ（`double` / `int` / `string` /
  `bool` / `vec2` / `vec3` / `vec4`）。ベクトルが裸の配列になるため値だけでは
  `vec2` と「2 要素配列」を区別できない問題を解消する。
- `sourceStamp`（v4 で追加）= ソース世代の刻印（provenance）。**consumer（cli）が
  子プロセス起動時に環境変数 `METAPHOR_SOURCE_STAMP` で注入**し、producer はそれを
  `frame.json` に echo する。編集ごとに変わる識別子（例: 監視対象ソースの mtime/サイズ
  集約ハッシュ、または build id）。AI／測定ハーネスが「観測フレームがどのソース版を
  反映するか」を判定し、保存→反映（リビルド→再起動）の完了を機械検出するために使う。
  未注入時は省略（nil）。
- **consumer 規約**: 未知のキーは無視する。`metaphor-cli` の MCP サーバは
  `frame.json` を **verbatim 透過**するため、additive なフィールド追加では cli の
  コード変更は不要（将来 cli が個別フィールドを解釈し始めたら本表に追記する）。
- キーのリネーム／削除／型変更は **破壊的変更**。`schemaVersion` を上げ、両リポジトリの
  本節を同時に更新し、`metaphor-cli` 側に対応 Issue/PR を立てること。

### wire スキーマの正典（契約点 4 の補足）

`request.json` / `frame.json` / `sequence.json` の **wire 形式（JSON の構造・キー・値域・
enum・`schemaVersion`）の正典は `contract/*.schema.json`**（JSON Schema draft 2020-12、
両リポジトリに同一内容で置く）。Swift 実装（`Sources/MetaphorCore/Probe/`）が意味の正典で、
スキーマはそれを機械可読に写したもの。設計判断は [docs/adr/0004-wire-schema-canon-vs-shared-types.md](docs/adr/0004-wire-schema-canon-vs-shared-types.md)
（Issue #119 案D 不採用・案C+ 採用）と [docs/design/external-coupling-and-contract.md](docs/design/external-coupling-and-contract.md)。

- **なぜ型共有ではないか**: consumer（cli）は Probe 契約型を decode せず `JSONSerialization` +
  `[String: Any]` で `request.json` を手組みするため、共有 SwiftPM 型ではコンパイル時保証が
  付かない。**wire schema は decode 不要で consumer の出力（`request.json`）まで機械検証できる**。
- **検証（二段）**: `scripts/check-contract-schema.sh` が `contract/examples/*.json` を各スキーマで
  検証（producer 出力・consumer 出力の双方の代表例）。producer 側の `ProbeSchemaConformanceTests`
  と consumer 側のツールテストが「実装が examples からドリフトしない」ことを守る。
- **保証されない**: 深い意味論（`contentBounds` の原点左上、`every` の既定値）は `description`
  止まりで強制されない（本 CONTRACT.md 散文と同等）。堅く強制できるのは構造・`customTypes` の
  `enum`・`contentBounds` の正規化範囲・`schemaVersion` の `const`。
- `scripts/check-contract.sh`（grep）は JSON 構造の検査から降り、**非 JSON 契約点**（環境変数名・
  `.metaphor/probe` パス・`request.json.tmp` の原子書き込み・`schemaVersion` の値・Syphon pin・
  doc パス・stdin 入力イベント）に縮小した。

### `request.json` のアトミック書き込み（契約点 4 の補足）

producer（metaphor）は `request.json` を mtime ポーリングで読み、変化したら 1 回読み取って
デコードする。**consumer は `request.json` を必ずアトミックに書く**こと——`request.json.tmp`
へ書いてから `request.json` へ rename する（出力側の `.tmp→rename` と対称）。これにより
producer が部分書き込み途中のファイルを読む TOCTOU を防ぐ。`metaphor-cli` の MCP サーバ
（`ProbeSnapshotTool` / `ProbeSequenceTool` の `writeRequest`）はこの規約に従う。非アトミックに
書く consumer はデコード失敗で無視される（producer は `METAPHOR_DEBUG=1` のとき stderr に
診断を出す）。同様に **`id` はリクエストごとに必ず変える**（producer は同一 id を再処理しない）。

### 連続フレーム出力 `sequence/`（契約点 4 の補足）

`request.json` に `frames >= 2` を指定すると、単一フレームの `current/frame.{png,json}`
ではなく `current/sequence/` 以下に連続フレーム列を書き出します（時間軸の観測用）。

- 出力レイアウト: `current/sequence/frame.NNNN.{png,json}`（0 始まり 4 桁ゼロ詰め）/
  `current/sequence/contact_sheet.png`（一覧モンタージュ）/ `current/sequence/sequence.json`（manifest）。
- `ProbeRequest` の任意フィールド: `frames`（採取枚数、`<=1` で従来の単一フレーム、
  **上限 64 にクランプ**——超過分は丸められ、manifest の `warnings[]` に
  `frames clamped from <N> to <M> (max 64)` が載る）/
  `every`（採取間隔ストライド、既定 1）。未知フィールドは無視する（consumer 規約）。
- `sequence.json` は独自の `schemaVersion`（現行 = 1）を持ち、`frame.json` と同じく
  **additive・前方互換**を原則とする。`frameCount` / `requestedFrames` / `every` / `size` /
  `contactSheet?` / `warnings[]` / `frames[]{index,file,metadata,frame,time}` を持つ。
- **完了規約**: シーケンス出力のうち `sequence.json` を**最後に**原子的に書き出す。
  consumer は「`sequence.json` が存在し、`id` がリクエストと一致し、`frames.count == frameCount`」で
  ready と判定する（単一フレームの `frame.json` mtime ポーリングと同型）。
- **新規パスの追加**である点に注意（additive だが、`current/frame.{png,json}` は不変）。
  `metaphor-cli` の MCP サーバはこれらを露出する `capture_sequence` ツールを**実装済み**
  （`ProbeSequenceTool.swift`。`request.json` に `frames>=2`(＋`every`)をアトミックに書き、
  `sequence.json` の ready 規約で contact sheet と manifest を返す。トークン自体は
  producer = metaphor が定義）。

### AI ドキュメント供給（契約点 6 の補足）

`metaphor new` で生成したスケッチは、`metaphor mcp` の `api_reference` ツールを通じて
依存先 metaphor の API ドキュメント（`llms.txt` / `llms-sketch.txt` /
`docs/ai/examples-index.md`）をエージェントへ供給する。`metaphor-cli` 側は
`MetaphorDocsLocator` で docs ルート（path 依存ならローカル checkout、url 依存なら
`.build/checkouts/metaphor`）を解決し、上記ファイル名で読む。

- **soft contract**: 未生成・未解決でも `api_reference` はエラーメッセージで graceful
  degrade する（クラッシュしない）。だが**ファイル名やパスのリネーム/削除**は
  `api_reference` を無言で劣化させるため、契約点として両側を揃える。
- producer（metaphor）側はこれらが**コミット済み**であることが前提。`llms.txt` と
  `docs/ai/examples-index.{md,json}` は生成物（`scripts/generate-llms-txt.py` /
  `scripts/generate-examples-index.py`）、`llms-sketch.txt` は**手書き**（生成器は無い）。
  生成物の出力先や手書きファイルの名前を変えるときは、本表とファイル名を更新し
  `metaphor-cli` 側に対応 PR/Issue を立てる。

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
- **wire スキーマ検証（L2c）**: 両リポジトリの CI が `scripts/check-contract-schema.sh`
  を実行し、`contract/examples/*.json` が `contract/*.schema.json` に適合するか
  `check-jsonschema` で検証します（JSON の構造・値域・enum・`schemaVersion` の検出。
  consumer が書く `request.json` を含む）。
- **byte-identity 検証（L2d）**: 両リポジトリの CI が `scripts/check-contract-identity.sh`
  を実行し、「両リポで同一内容」と宣言されたファイル群 — `CONTRACT.md`・
  `contract/` 配下全ファイル（`README.md` / `*.schema.json` / `examples/*.json`）・
  共有スクリプト（`check-contract.sh` / `check-contract-schema.sh` /
  `check-contract-identity.sh` 自身）— を他方のリポジトリと byte 単位で比較します
  （同名ブランチ優先・既定ブランチへフォールバック。片側のみの追加・削除も検出）。
  対になる変更は**両リポで同名ブランチ**の PR にすること。
- **Syphon pin 自動 bump（L2a）**: `metaphor` の安定版 Release 時に
  `repository_dispatch`（`event_type: syphon-release`）で `metaphor-cli` へ
  通知し、`metaphor-cli` 側のワークフローが `Package.swift` の URL + checksum を
  更新する PR を自動作成します。

## 関連ファイル

### 両リポジトリ共通
- `contract/*.schema.json` / `contract/examples/*.json` / `contract/README.md` — Probe wire 形式の正典（同一内容で両リポに置く）
- `scripts/check-contract.sh` — 非 JSON 契約点のトークン存在チェック（同一スクリプト）
- `scripts/check-contract-schema.sh` — examples をスキーマで検証（同一スクリプト）
- `scripts/check-contract-identity.sh` — 上記すべて＋自分自身の byte-identity を検証（同一スクリプト）

### metaphor
- `Sources/MetaphorCore/Sketch/SketchRunner.swift` — 環境変数読み取り・headless
- `Sources/MetaphorCore/Input/InputInjectionPlugin.swift` — stdin JSON Lines 解析
- `Sources/MetaphorCore/Probe/MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift` / `ProbeRequest.swift` / `ProbeSequenceManifest.swift` — Probe 契約（単一フレーム + 連続フレーム）
- `llms.txt` / `docs/ai/examples-index.{md,json}`（生成物）・`llms-sketch.txt`（手書き）— AI ドキュメント（契約点 6）
- `.github/workflows/release.yml` — Syphon ビルド・Release・cli への dispatch

### metaphor-cli
- `Sources/MetaphorViewer/ViewerWatch.swift` — 子プロセス起動・環境変数設定・stdin 転送
- `Sources/MetaphorViewer/ViewerWindow.swift` — 入力イベントの JSON Lines 送出
- `Sources/MetaphorViewer/SyphonFrameSource.swift` — Syphon 受信
- `Sources/MetaphorCLICore/MCP/ProbeSnapshotTool.swift` / `MCP/ProbeSequenceTool.swift` — `snapshot` / `capture_sequence`（契約点 4。`request.json` をアトミックに書き、`frame.json` / `sequence.json` の ready 規約で読む）
- `Sources/MetaphorCLICore/MCP/MetaphorDocsLocator.swift` / `MCP/SketchToolHandler.swift` — `api_reference`（契約点 6）
- `Package.swift` — Syphon.xcframework の Release pin
- `.github/workflows/syphon-bump.yml` — dispatch 受信で pin を更新する PR を作成
