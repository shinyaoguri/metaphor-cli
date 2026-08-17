# CONTRACT.md — metaphor ⇄ metaphor-cli の連携契約

> **対象読者**: 本ドキュメントは metaphor / metaphor-cli の**メンテナー・開発者向け**です。
> スケッチを書くだけの方（および生成プロジェクトから辿ってきた AI エージェント）が読む必要はありません —
> スケッチ作者向けの入口は `llms-sketch.txt` と `docs/ai/for-sketch-authors.md` です。
>
> スケッチユーザーにとってこの契約が持つ意味は一言でいえば「**AI が実行中のスケッチの描画結果と
> 内部状態を観測し、入力を送り、反映を確認できる**」ことの土台です。`metaphor watch` /
> `metaphor mcp` を使うだけなら、ここに書かれた配線は意識せずとも自動で機能します。

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
  **MCP サーバ**（`snapshot` / `capture_sequence` / `input` / `params` / `set_param` /
  `build_status` / `api_reference` の 7 ツール）として AI エージェントへ露出する。
  下表の **consumer（依存側）**。`params` / `set_param` は契約点 7（Parameter Store）の
  consumer で、共有セッション（`metaphor watch` へアタッチ）でも有効——ファイル契約なので
  子の stdin を watch が所有していても使える。stdin 経由の `input` だけが共有セッションで
  無効になる。

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
| 2 | **環境変数**<br>`METAPHOR_VIEWER` / `METAPHOR_SYPHON_NAME` / `METAPHOR_FPS` / `METAPHOR_PROBE` / `METAPHOR_SOURCE_STAMP` / `METAPHOR_STATE_DIR` | `metaphor` が読む（`SketchRunner.swift`。**`METAPHOR_VIEWER` は 4 箇所が読む** = `SketchRunner.swift`（プライマリのヘッドレス化）/ `SketchWindow.swift`（セカンダリウィンドウのヘッドレス化）/ `Sketch+Files.swift`（`selectInput()` / `selectOutput()` をダイアログ無しの no-op へ）/ `State/StatePlugin.swift`（契約点 8 の自動有効化）。`METAPHOR_SOURCE_STAMP` は `MetaphorProbePlugin.swift`、`METAPHOR_STATE_DIR` は `MetaphorPaths.swift`） | `metaphor-cli` が設定（`ViewerWatch.swift` / `Watch.swift`） |
| 3 | **stdin 入力イベント（JSON Lines）**<br>キー `t` の値 `mouseDown` `mouseUp` `mouseMove` `mouseDrag` `scroll` `keyDown` `keyUp`、フィールド `x` `y` `button` `code` `chars` `repeat` `dx` `dy`。バージョン番号は持たず、未知の `t` / 未知のフィールドは無視される（下記補足） | `metaphor` が解析（`InputInjectionPlugin.swift`） | `metaphor-cli` が送出（`ViewerWindow.swift`） |
| 4 | **Probe ファイル契約**<br>`.metaphor/probe/request.json`（リクエスト）/ `.metaphor/probe/current/frame.{png,json}`（単一フレーム出力）/ `.metaphor/probe/current/sequence/`（連続フレーム出力）と `frame.json` / `sequence.json` スキーマ、`ProbeRequest` のフィールド（`id` / `label` / `scale` / `frames` / `every`） | `metaphor`（`MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift` / `ProbeSequenceManifest.swift` / `ProbeRequest.swift`） | AI エージェント・ツール（`metaphor-cli` の `snapshot` / `capture_sequence`） |
| 5 | **Syphon サーバー名 / headless 挙動**<br>`METAPHOR_VIEWER=1` で `METAPHOR_SYPHON_NAME` のサーバーへ publish。**publish されるフレームは premultiplied alpha**（下記補足） | `metaphor` headless モード（`SketchRunner.swift` / `MetaphorSyphon`） | `metaphor-cli`（`SyphonFrameSource.swift`） |
| 6 | **AI ドキュメント／wire スキーマのパス・ファイル名**<br>`llms.txt` / `llms-sketch.txt` / `docs/ai/examples-index.{md,json}` / `contract/*.schema.json` | `metaphor` が用意（`llms.txt` / `examples-index` は生成物＝`make llms-txt` / `make examples-index`、`llms-sketch.txt` は**手書き**。`contract/` は両リポ identical な正典。いずれもリポジトリにコミット） | `metaphor-cli` の MCP `api_reference` ツール（`MetaphorDocsLocator.swift` / `SketchToolHandler.swift`） |
| 7 | **Parameter Store ファイル契約**<br>`.metaphor/params/params.json`（現在値 + 宣言情報の出力）/ `.metaphor/params/set-request.json`（外部からの更新要求）と `params.schema.json` / `param-set-request.schema.json`、環境変数 `METAPHOR_PARAMS`（`0` でオプトアウト） | `metaphor`（`Sources/MetaphorCore/Parameters/` の `ParameterPlugin.swift` / `ParameterFile.swift` / `ParameterStore.swift`） | AI エージェント・ツール（`metaphor-cli` の `params` / `set_param` MCP ツール = `MCP/ParameterStoreTool.swift`） |
| 8 | **状態保持リロードのファイル契約**<br>`.metaphor/state/state.json`（保存された状態）/ `.metaphor/state/save-request.json`（外部からの保存要求）と `state.schema.json` / `state-save-request.schema.json`、環境変数 `METAPHOR_STATE`（`1` で明示有効・`0` でオプトアウト）/ `METAPHOR_RESTORE_STATE`（復元元のパス） | `metaphor`（`Sources/MetaphorCore/State/` の `StatePlugin.swift` / `SketchStateFile.swift`） | `metaphor-cli` の watch（リビルド時の保存 → 再起動時の注入） |

### `.metaphor/` の基準ディレクトリ `METAPHOR_STATE_DIR`（契約点 2 / 4 / 7 / 8 の補足）

`.metaphor/probe/`（契約点 4）・`.metaphor/params/`（契約点 7）・`.metaphor/state/`（契約点 8）は
**プロセスの cwd 相対**で解決されます。`swift run` ならプロジェクト直下が cwd になるので
問題ありませんが、**`.app` を LaunchServices から起動すると cwd が `/`** になり、
どれも書けない場所を向きます（常設運用に近い形 — `open` で起動 / ログイン項目 / Dock から
起動 — で Probe の応答が返らない・パラメータが永続化されない）。

環境変数 `METAPHOR_STATE_DIR` に基準ディレクトリを与えると、**相対パスはそこから**
解決されます。

- **producer（metaphor）**: Probe / Parameter Store / State の 3 つが同じ基準を見る
  （`Sources/MetaphorCore/Utilities/MetaphorPaths.swift`）。プロセス起動時に 1 度だけ評価する
- **consumer（metaphor-cli）**: 同じ変数を尊重して `.metaphor/` を探す。`run` / `watch` は
  子プロセスへそのまま渡す
- **未設定なら従来どおり cwd 相対**（既定の挙動は変わらない・additive な追加）
- 値が相対パス・`~` 始まりのときは、読み取り側の cwd 基準で絶対化してから使う
- 絶対パスで与えた個別の設定（`MetaphorProbeConfig.outputDirectory` など）は影響を受けない

```bash
open -n .build/strata.app --env METAPHOR_PROBE=1 --env "METAPHOR_STATE_DIR=$PWD"
```

### stdin 入力イベントの互換規約（契約点 3 の補足）

契約点 3 は **1 行 1 イベントの JSON Lines を consumer → producer へ一方向に流すだけ**の
ストリームで、**バージョン番号を持ちません**。代わりに次の 3 つの「無視」で前方互換を閉じます
（いずれも実装済みの挙動で、ここはその明文化です）。

- **未知の `t` は無視する** — producer は既知のイベント種別だけを `switch` で処理し、
  `default` では何もしない（`InputInjectionPlugin.swift` の `dispatch(_:to:)`）。新しい種別を
  送っても、古い producer に当たったときに落ちるのは**そのイベントだけ**でプロセスは死なない。
- **未知のフィールドは無視する** — 1 行は `RawInputEvent`（`Decodable`）へデコードされ、
  知らないキーは捨てられる。**フィールドの追加は additive**（必須は `t` だけで、他は
  すべて任意。欠落時はゼロ既定値が補われる）。
- **不正な JSON 行は無視する** — デコードに失敗した行は読み飛ばし、`METAPHOR_DEBUG=1` の
  ときだけ stderr へ診断を出す。1 行の壊れが以降の入力を止めない。

**バージョン番号は導入しません**（Issue #339 の決着）。理由は 3 つ:

1. 上の「無視」で**前方互換がすでに閉じている** — consumer が新しい `t` やフィールドを
   送っても、古い producer が壊れることはない。
2. `frame.json` と違い **consumer → producer の一方向ストリーム**で、producer は
   このチャネルへ何も書き返さない。バージョンを名乗っても**ネゴシエーションする相手が
   いない**（受け手が能力を申告する経路が無い）。
3. 「送ったのに効かない」の切り分けは、バージョン番号ではなく**観測側**——Probe の
   `frame.json`（契約点 4）と `METAPHOR_DEBUG=1` の診断——で行うのが実際の運用に合う。

イベント種別・フィールドを**増やす**ときは、producer（`InputInjectionPlugin.swift`）と
consumer（`metaphor-cli` の `ViewerWindow.swift`）の両方 + 契約点 3 の表 +
`scripts/check-contract.sh` のトークン一覧を 1 セットで更新すること（同スクリプトは
両側についてタグ名とフィールド名の生存を検査します）。既存の `t` の**意味**や
フィールドの**型**を変えるのは破壊的変更で、この「無視」では吸収できません。

### `frame.json` スキーマのバージョニング（契約点 4 の補足）

`frame.json` は `schemaVersion`（整数）を持ち、**前方互換の additive 変更**を原則とします。

- **現行 = `schemaVersion: 4`**。トップレベルキー: `schemaVersion` / `id` / `label?` /
  `sourceStamp?` / `frame` / `time` / `size{width,height}` / `custom{}` / `customTypes{}` /
  `warnings[]` / `stats?` / `performance?` / `params?` / `shaders?`。
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
- `performance`（`schemaVersion: 4` のまま additive 追加、Issue #271）= リクエスト
  処理時に採取する実測パフォーマンス統計。スケッチの「重い/軽い」を AI が画像からの
  推測でなく数値で判断するためのシグナル。`fps?`（直近約 1 秒の実測値。noLoop 停止中・
  起動直後は省略）/ `targetFPS`（`frameRate()` / `METAPHOR_FPS` 解決後の設定値）/
  `frameTimeMs?{mean,max}`（ミリ秒。`max` はスパイク検出用）/ `memoryMB?`
  （phys_footprint、Activity Monitor の「メモリ」相当）/ `cpuPercent?`（前回リクエスト
  から今回まで＝初回はスケッチ起動からの平均。**1 コア = 100%**、`top` 互換）/
  `thermalState`（`nominal` / `fair` / `serious` / `critical` / `unknown`）。
  **単一フレーム経路（`current/frame.json`）のみ**で搭載され、連続キャプチャ
  （`sequence/frame.NNNN.json`）・失敗応答・採取不能時はキー省略。
- `params`（`schemaVersion: 4` のまま additive 追加、Issue #424）= このフレームを
  生んだ Parameter Store（契約点 7）の値スナップショット。`revision`（ストアの
  単調増加カウンタ。`params.json` の `revision` と同じ意味）/ `values{}`（パラメータ名 →
  現在値。型タグの無い裸の JSON）。**型・レンジ・`choices` の正典は `params.json` 側**で、
  ここは値のスナップショットに徹する（wire を小さく保つ）。`@Param` が 1 つも
  宣言されていないスケッチではキー省略。**単一フレーム経路と連続キャプチャの両方**に
  載る（メモリ内の読み取りのみで syscall が無く、シーケンス中に外部が値を変えた
  フレームを `revision` で切り分けられる）。失敗応答では省略。
- `shaders`（`schemaVersion: 4` のまま additive 追加、Issue #671）= このフレームを描いた
  **ファイル由来シェーダのホットリロード世代**。`sourceStamp` はプロセス起動時に固定される
  ため、`.metal` の保存が**再起動なしで**絵を変えるホットリロード（metaphor #648）を刻印で
  追えない。ここは**差し替えが着地した後にしか動かない**世代情報を載せる。
  `generation`（起動からの着地回数。差し替えが 1 つでも成功したリロードごとに +1。単調増加
  なので「編集して元に戻す」でも取りこぼさないが、プロセス再起動で 0 に戻る）/ `digest`
  （いま載っているファイル由来シェーダ全体の集約ハッシュ。内容由来なので**再起動をまたいで**
  比較できる。**consumer は不透明な識別子として等値比較のみ**行い、長さや算出法に依存しない）
  / `lastError?`（直近のリロードのコンパイルエラー。全て成功していれば省略）。
  **ファイル由来のシェーダが 1 つも無いスケッチ**（ホットリロード無効時を含む）ではキー省略。
  **単一フレーム経路と連続キャプチャの両方**に載る。失敗応答では省略。
  - **consumer 手順（保存 → 反映の機械検出）**: ① snapshot して `shaders.generation` を控える
    → ② `.metal` を保存 → ③ snapshot をポーリングし、`generation` が進んだら**着地**、
    `lastError` が出たら**コンパイル失敗**（直して保存し直す）、どちらでもなければまだ窓の中。
    デバウンスやコンパイル中に値が動かないため「新しい刻印・古い描画」の偽陽性が出ない。
    リビルド → 再起動を伴う `.swift` 側の編集は従来どおり `sourceStamp` で判定する。
- **consumer 規約**: 未知のキーは無視する。`metaphor-cli` の MCP サーバは
  `frame.json` を **verbatim 透過**するため、additive なフィールド追加では cli の
  コード変更は不要（将来 cli が個別フィールドを解釈し始めたら本表に追記する）。
- 据え置き / bump の判定と手順は「[`schemaVersion` bump 規則](#schemaversion-bump-規則)」に
  集約してある（`frame.json` 固有ではなく全 wire 共通の規則）。

### wire スキーマの正典（契約点 4 の補足）

`request.json` / `frame.json` / `sequence.json`（契約点 4）と `params.json` /
`set-request.json`（契約点 7）、`state.json` / `save-request.json`（契約点 8）の
**wire 形式（JSON の構造・キー・値域・
enum・`schemaVersion`）の正典は `contract/*.schema.json`**（JSON Schema draft 2020-12、
両リポジトリに同一内容で置く）。Swift 実装（`Sources/MetaphorCore/Probe/` /
`Sources/MetaphorCore/Parameters/` / `Sources/MetaphorCore/State/`）が意味の正典で、
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

### 失敗応答（契約点 4 の補足）

producer はフレームを採取できなかったとき（staging テクスチャ確保失敗等）も**無応答にしない**。
consumer がタイムアウトではなく id 一致で失敗を検知できるよう、次の規約で応答する:

- **単一フレーム経路**: 失敗理由を `warnings[]` に載せた `frame.json` **だけ**を書く
  （PNG は書かない）。前回応答の `frame.png` が残っていれば**削除してから** `frame.json` を
  書く——consumer が新しい id の `frame.json` と古い画像を組にしないため。
  wire 形式は通常の `frame.json` と同一（`contract/examples/frame-failure.json` が正典サンプル）。
- **連続フレーム経路**: 失敗理由を `warnings[]` に載せた `sequence.json`（manifest）で応答する
  （従来どおり）。
- **consumer 規約**: id が一致する `frame.json` に対して `frame.png` が存在しなければ
  失敗応答である。`warnings[]` を失敗理由としてエージェントへ返すこと
  （タイムアウトまで待つ必要はない）。

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

### Syphon フレームのアルファ（契約点 5 の補足）

`metaphor` が publish するフレームは **premultiplied alpha** です。レンダーターゲットが
premultiplied で（[ADR-0012](docs/adr/0012-alpha-semantics.md)）、`MetaphorSyphon` は
それを**変換せず無加工で** Syphon サーバーへ渡します（`Sources/MetaphorSyphon/SyphonOutput.swift`）。

- **受け手は premultiplied `over` で合成すること** — `result = src.rgb + dst.rgb * (1 - src.a)`。
  straight alpha の `over`（`src.rgb * src.a + …`）で合成すると α が二重に掛かり、
  半透明部が暗く沈む。Syphon 側の wire にアルファ種別を申告する経路は無いため、
  これは**規約でしか伝えられない**（だから契約点に書く）。
- consumer（`metaphor-cli`）は既にこの前提で動いており、**実装変更は不要**
  （`SyphonFrameSource.swift` は受け取ったテクスチャを変換せず扱い、`FrameCapture.swift` は
  `premultipliedFirst` で読む）。MadMapper / VDMX / Resolume など一般の Syphon
  クライアントも premultiplied を既定とする。
- **他の出力先とは α の扱いが違う**点に注意（正典は ADR-0012「外部出力での扱い」表）。
  PNG / Probe / GIF は `premultipliedLast` と宣言して ImageIO に割り戻させるので
  **ファイルは straight**、動画（h264 / hevc）は**コーデックが α を持てないので黒に
  合成済みの RGB** が残る。**外へ premultiplied のまま出るのは Syphon だけ**。

### Parameter Store `.metaphor/params/`（契約点 7）

スケッチが `@Param` で宣言したパラメータを、**再ビルドなしで外部から読み書きする**ための
ファイル契約です。Probe（契約点 4）と同じ流儀——アトミック書込・mtime ポーリング・
`id` エコー・`contract/*.schema.json` が wire 形式の正典——を `.metaphor/` 配下の
別ファセットとして再利用します（新しい RPC は作らない）。

- **`params.json`（producer = スケッチが唯一の書き手）**: `schemaVersion`（現行 = 1）/
  `revision`（値が変わるたびに増える単調カウンタ。プロセス起動時にも 1 つ進む）/
  `appliedRequestId?`（最後に処理した set-request の `id` エコー）/ `warnings[]`
  （直近の set-request で拒否された理由）/ `params[]{name,type,value,min?,max?,choices?}`
  （**宣言順**）。型セットは `float` / `int` / `bool` / `string` / `color` / `vec2` / `vec3`
  で、`value` の JSON 形状は `type` が決める（`vec2` / `vec3` / `color` は 2 / 3 / 4 要素の
  数値配列）。書き出しは `params.json.tmp` → rename の**アトミック書込**。
- **`set-request.json`（consumer = AI エージェント / ツールが書く）**: `{id, values{name: value}}`。
  **consumer は必ずアトミックに書く**こと（`set-request.json.tmp` → rename。契約点 4 の
  `request.json` と同じ理由）。**`id` はリクエストごとに必ず変える**（producer は同一 id を
  再処理しない）。producer は次フレームの `pre()` で読み、宣言された型に沿って解釈する。
- **拒否と反映確認**: 未知の名前・型不一致・`choices` 外の値は**適用されず**、理由が
  `params.json` の `warnings[]` に載る（全件拒否でも `appliedRequestId` は更新されるため、
  consumer はタイムアウトを待たずに結果を判定できる）。`min` / `max` を持つ数値は
  外部からの書き込みがその範囲に**クランプ**される。競合ポリシーは
  **last-writer-wins**（人間の GUI ドラッグと `set_param` は同一ストアの対称クライアント）。
- **永続化**: 値が変わると `params.json` が書き直され（GUI ドラッグ等は ~200ms デバウンス、
  set-request 起因は即時）、次回起動時に**名前 + 型が一致するものだけ**復元される
  （型が変わった値は破棄）。`setup()` / `draw()` は最初から復元値を見る。
- **有効化**: `@Param` が 1 つでも宣言されていれば自動（素の `swift run` でも永続化が効く）。
  オプトアウトは環境変数 `METAPHOR_PARAMS=0`（契約点 2 の env var 群と同じ扱い）。
- **`frame.json` との関係**: Probe のスナップショット（契約点 4）は `params{revision,values}`
  を同梱する。**画像とパラメータが 1 回の書き出しで揃う**ため、consumer は
  「この絵はどの値のときのものか」を 2 ファイルの読み取りタイミングに賭けずに確定できる。
  `params.json` は宣言情報（型・レンジ・`choices`）と反映確認（`appliedRequestId` /
  `warnings`）の正典で、`frame.json` 側は値のスナップショットに徹する。
- **consumer 規約**: 未知のキーは無視する（`frame.json` と同じ additive ルール）。
  据え置き / bump の判定と手順は「[`schemaVersion` bump 規則](#schemaversion-bump-規則)」に従う。
- **実装状況**: producer（metaphor）・consumer とも実装済み。consumer 側は
  `metaphor-cli` の MCP ツール `params`（読み取り）/ `set_param`（書き込み →
  `appliedRequestId` のエコー待ち。全件拒否でも更新されるためタイムアウトを待たない）で、
  実装は `MCP/ParameterStoreTool.swift`。`set_param` は**ファイル契約なので共有セッション
  （動作中の `metaphor watch` にアタッチした `metaphor mcp`）でも使える**——子の stdin を
  watch が所有するために使えない `input` とは、この点で異なる。MCP を介さず、AI
  エージェントが 2 ファイルを直接読み書きしても同じ操作ができる（cli 非依存の
  ライブラリ機能である点は Probe と同じ）。

### 状態保持リロード `.metaphor/state/`（契約点 8）

`metaphor watch` は再ビルドのたびに子プロセスを作り直すため、既定では `draw()` が積み上げた
状態（パーティクル・シミュレーション）と時計（`frameCount` / `time`）が毎回ゼロに戻ります。
本契約はその 2 つを**次のプロセスへ運ぶ**ためのもので、Probe（契約点 4）・Parameter Store
（契約点 7）と同じ流儀——アトミック書込・mtime ポーリング・`id` エコー・
`contract/*.schema.json` が wire 形式の正典——を `.metaphor/` 配下の別ファセットとして
再利用します（新しい RPC は作らない）。パラメータ（`@Param`）は契約点 7 が単独で
リロードを生存するため、本契約が運ぶのは**それ以外の状態と時計**です。

- **`save-request.json`（consumer = `metaphor watch` が書く）**: `{id}`。**アトミックに書く**
  こと（`save-request.json.tmp` → rename）。**`id` はリクエストごとに必ず変える**
  （producer は同一 id を再処理しない）。producer は次フレームの `pre()` で読む。
- **`state.json`（producer = スケッチが唯一の書き手）**: `schemaVersion`（現行 = 1）/
  `savedRequestId?`（応答した save-request の `id` エコー）/ `runtime{frameCount,elapsedSeconds}`
  （metaphor 自身が復元する時計）/ `user?{encoding,data}`（`Sketch.saveState()` が返した
  ペイロード。現行 `encoding` は `base64` のみ）。書き出しは `state.json.tmp` → rename の
  **アトミック書込**で、`params.json` と違い**同期**（consumer はこのファイルを見てから子を
  kill するため、書き出し完了がそのままリロードの待ち時間になる）。
- **`user` 節は意図的に opaque**: エンベロープだけがスキーマ管理の対象で、`data` の中身は
  スケッチ作者のものです。consumer は解釈せず運ぶだけ（型を知る必要がない = cli を
  スケッチのデータモデルから独立に保つ）。
- **消費シーケンス（consumer 側）**: リビルド成功 → `save-request.json` を書く →
  `state.json` の `savedRequestId` が送った `id` と一致するまでポーリング（**タイムアウト
  ~250ms**）→ 子を kill → 新しい子を `METAPHOR_RESTORE_STATE=<state.json の絶対パス>`
  付きで起動。タイムアウト・ファイル無しは**状態なしで通常起動**（開発ツールがリロードを
  止めない）。
- **復元（producer 側）**: `METAPHOR_RESTORE_STATE` があれば起動時に読み、`setup()` の**後**に
  `Sketch.restoreState(_:)` へ `user` ペイロードを渡す。`runtime`（時計）の復元は
  `SketchConfig.preserveClock = true` のときだけ行う（既定 `false` = オプトイン。時刻が
  外部の都合で飛ぶことを前提にしないスケッチを驚かせないため）。**デコード失敗・欠損・
  未知の `encoding` はすべて黙って初期状態へフォールバック**する（`METAPHOR_DEBUG=1` の
  ときだけ stderr に理由を出す）。
- **有効化**: ヘッドレス（`METAPHOR_VIEWER=1` = watch の子プロセス）で自動。素の
  `swift run` で試すときは `METAPHOR_STATE=1`、オプトアウトは `METAPHOR_STATE=0`。
  リクエストが無いフレームのコストは save-request の `stat()` 1 回（契約点 4/7 と同じ
  性能契約）。**consumer 側の規約**: `metaphor watch` は子へ `METAPHOR_STATE=1` を
  明示注入する（`--no-viewer` でも状態が運ばれるように。ユーザーが環境で
  `METAPHOR_STATE` を設定していればそれを尊重する）。また、**保存要求が一度も
  応答されなかった watch セッションでは以降の要求を止める** — 状態保持を使っていない
  スケッチでリロードのたびにタイムアウトぶん待たないため。
- **consumer 規約**: 未知のキーは無視する（additive ルール）。据え置き / bump の判定と
  手順は「[`schemaVersion` bump 規則](#schemaversion-bump-規則)」に従う。

### AI ドキュメント供給（契約点 6 の補足）

`metaphor new` で生成したスケッチは、`metaphor mcp` の `api_reference` ツールを通じて
依存先 metaphor の API ドキュメント（`llms.txt` / `llms-sketch.txt` /
`docs/ai/examples-index.md`）をエージェントへ供給する。`metaphor-cli` 側は
`MetaphorDocsLocator` で docs ルート（path 依存ならローカル checkout、url 依存なら
`.build/checkouts/metaphor`）を解決し、上記ファイル名で読む。

**wire スキーマも同じ経路で供給する**（`api_reference doc=contract`）。docs ルート直下の
`contract/<schema>.schema.json` を読む（既定 `frame`、`schema` 引数で
`request` / `sequence` / `params` / `param-set-request` / `state` / `state-save-request`）。
GitHub の main ブランチではなく **checkout から読むこと自体が要点**で、エージェントが
手にするスキーマが依存バージョンぴったりになる（`contract/` は両リポ identical なので、
どちら側の checkout でも同じものが得られる）。

- **soft contract**: 未生成・未解決でも `api_reference` はエラーメッセージで graceful
  degrade する（クラッシュしない）。だが**ファイル名やパスのリネーム/削除**は
  `api_reference` を無言で劣化させるため、契約点として両側を揃える。
- producer（metaphor）側はこれらが**コミット済み**であることが前提。`llms.txt` と
  `docs/ai/examples-index.{md,json}` は生成物（`scripts/generate-llms-txt.py` /
  `scripts/generate-examples-index.py`）、`llms-sketch.txt` は**手書き**（生成器は無い）。
  生成物の出力先や手書きファイルの名前を変えるときは、本表とファイル名を更新し
  `metaphor-cli` 側に対応 PR/Issue を立てる。

## 契約のフリーズ点

v1.0 は SemVer 契約の凍結宣言です（昇格条件は `docs/design/v1-release-plan.md`）。
**そのとき凍結される wire 面がどれか**を、判断のたびに散文を読み直さなくて済むよう
ここで名指しします。各面のキー集合の正典は本ファイルの該当節と `contract/*.schema.json` で、
下表はその索引です。

| 面 | 現行バージョン | キー集合の正典 |
|---|---|---|
| 契約環境変数（契約点 2） | — | 契約点 2 の表の名前（+ 契約点 7 の `METAPHOR_PARAMS` / 契約点 8 の `METAPHOR_STATE` / `METAPHOR_RESTORE_STATE`） |
| stdin 入力イベント（契約点 3） | **バージョン番号なし**（「stdin 入力イベントの互換規約」参照） | 契約点 3 の表の `t` 値とフィールド名 |
| `request.json`（契約点 4） | `schemaVersion` なし | `contract/request.schema.json` |
| `frame.json`（契約点 4） | `schemaVersion: 4` | 「`frame.json` スキーマのバージョニング」節 + `contract/frame.schema.json`（トップレベル 14 キー: `schemaVersion` / `id` / `label?` / `sourceStamp?` / `frame` / `time` / `size` / `custom` / `customTypes` / `warnings` / `stats?` / `performance?` / `params?` / `shaders?`） |
| `sequence.json`（契約点 4） | `schemaVersion: 1` | 「連続フレーム出力 `sequence/`」節 + `contract/sequence.schema.json` |
| Syphon フレーム（契約点 5） | — | サーバー名の解決 + **premultiplied alpha**（「Syphon フレームのアルファ」節） |
| AI ドキュメントのパス（契約点 6） | — | 契約点 6 の表のファイル名 |
| `params.json` / `set-request.json`（契約点 7） | `schemaVersion: 1` / なし | 「Parameter Store」節 + `contract/params.schema.json` / `contract/param-set-request.schema.json` |
| `state.json` / `save-request.json`（契約点 8） | `schemaVersion: 1` / なし | 「状態保持リロード」節 + `contract/state.schema.json` / `contract/state-save-request.schema.json` |

**凍結は「追加禁止」ではありません。** additive な追加は凍結後も下記 bump 規則の
「据え置き」条件を満たす限り行えます。凍結が禁じるのは**既存の名前・型・意味を
削る／変える**ことです。

### `schemaVersion` bump 規則

`frame.json` / `sequence.json` / `params.json` / `state.json` に共通の規則です
（4 つはそれぞれ独立した `schemaVersion` を持ちます）。`request.json` /
`set-request.json` / `save-request.json` は `schemaVersion` を持たない consumer 出力なので、
**「据え置き」の行だけ**が該当します（未知フィールドは producer が無視する）。

| 変更 | 判定 | 併せて行うこと |
|---|---|---|
| **キーの追加**で、consumer が解釈しなくても機能が成立する | **据え置き** | 本ファイルの該当節と `contract/*.schema.json` に追記（`additionalProperties: false` なので**スキーマへの追記は必須**）。cli のコード変更は不要 |
| **キーの追加**で、consumer が解釈しないと機能が成立しない | **bump** | 追加と同時に consumer 側の解釈を入れ、両リポの本ファイルを同時に更新 |
| **enum / 値域の拡大**（新しい `thermalState` の値など） | **据え置き** | consumer は未知の値を落とさず素通しすること |
| **キーのリネーム・削除・型変更** | **bump**（破壊的変更） | 両リポの本ファイルを同時に更新し、対向リポに対応 Issue / PR を立てる |
| **意味の変更**（名前も型も同じまま解釈が変わる） | **bump**（破壊的変更） | 同上。`scripts/check-contract.sh` はトークンの生存しか見ないので**素通りする**——ここは人間と本ファイルが唯一の防壁 |

先例: `performance`（#271）/ `params`（#424）/ `shaders`（#671）は 3 つとも
「consumer が解釈しなくても既存機能は成立する」ため `schemaVersion: 4` 据え置きで追加した。
**将来 cli がそのキーを解釈し始めたとき**は、キー自体は変わらないので bump ではなく
本ファイルの該当節へ「cli が解釈する」ことを追記する（consumer が壊れる変更ではないため）。

## 変更時のルール（エージェント・人間共通）

「契約点」の表のトークン（環境変数名・JSON のキー/値・Probe のパスやスキーマ・Syphon の
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
- `Sources/MetaphorCore/Sketch/SketchRunner.swift` — 環境変数読み取り・プライマリのヘッドレス化（契約点 2 / 5）
- `Sources/MetaphorCore/Sketch/SketchWindow.swift` — `METAPHOR_VIEWER` によるセカンダリウィンドウのヘッドレス化（契約点 2）
- `Sources/MetaphorCore/Sketch/Sketch+Files.swift` — `METAPHOR_VIEWER` のとき `selectInput()` / `selectOutput()` をダイアログ無しの no-op + warning へ落とす（契約点 2）
- `Sources/MetaphorSyphon/SyphonOutput.swift` / `SyphonPlugin.swift` — Syphon publish（契約点 5。premultiplied alpha を無加工で渡す）
- `Sources/MetaphorCore/Input/InputInjectionPlugin.swift` — stdin JSON Lines 解析（契約点 3。未知の `t` / 未知フィールド / 不正な行を無視する互換規約の実装）
- `Sources/MetaphorCore/Probe/MetaphorProbeConfig.swift` / `ProbeFrameMetadata.swift` / `ProbeRequest.swift` / `ProbeSequenceManifest.swift` — Probe 契約（単一フレーム + 連続フレーム）
- `Sources/MetaphorCore/Parameters/ParameterPlugin.swift` / `ParameterFile.swift` / `ParameterStore.swift` / `Param.swift` — Parameter Store 契約（契約点 7。`.metaphor/params/` のパス・`METAPHOR_PARAMS`・wire 形式）
- `Sources/MetaphorCore/State/StatePlugin.swift` / `SketchStateFile.swift` / `Sketch+State.swift` — 状態保持リロード契約（契約点 8。`.metaphor/state/` のパス・`METAPHOR_STATE` / `METAPHOR_RESTORE_STATE`・wire 形式。`StatePlugin` は自動有効化の判定で `METAPHOR_VIEWER` も読む = 契約点 2）
- `llms.txt` / `docs/ai/examples-index.{md,json}`（生成物）・`llms-sketch.txt`（手書き）— AI ドキュメント（契約点 6）
- `.github/workflows/release.yml` — Syphon ビルド・Release・cli への dispatch

### metaphor-cli
- `Sources/MetaphorViewer/ViewerWatch.swift` — 子プロセス起動・環境変数設定・stdin 転送
- `Sources/MetaphorViewer/ViewerWindow.swift` — 入力イベントの JSON Lines 送出
- `Sources/MetaphorViewer/SyphonFrameSource.swift` — Syphon 受信（契約点 5。premultiplied のまま受け取る）
- `Sources/MetaphorCLICore/MCP/ProbeSnapshotTool.swift` / `MCP/ProbeSequenceTool.swift` — `snapshot` / `capture_sequence`（契約点 4。`request.json` をアトミックに書き、`frame.json` / `sequence.json` の ready 規約で読む）
- `Sources/MetaphorCLICore/MCP/MetaphorDocsLocator.swift` / `MCP/SketchToolHandler.swift` — `api_reference`（契約点 6）
- `Package.swift` — Syphon.xcframework の Release pin
- `.github/workflows/syphon-bump.yml` — dispatch 受信で pin を更新する PR を作成
