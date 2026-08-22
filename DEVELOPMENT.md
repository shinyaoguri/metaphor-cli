# metaphor-cli Development

このドキュメントは `metaphor-cli`（CLI ツール本体）を開発する人向けです。

CLI の使い方は [README.md](README.md) を参照してください。`metaphor` ライブラリ本体の開発は、
sibling リポジトリ [shinyaoguri/metaphor](https://github.com/shinyaoguri/metaphor) の
`DEVELOPMENT.md` を参照してください。

## Build & Test

```bash
make setup                # 初回のみ: pre-push フック（クロスリポ契約チェック）を導入
swift build               # デバッグビルド
swift test                # テスト実行
swift run metaphor --help # ローカルビルドを直接実行
make release              # リリースビルド
make install              # release ビルドを ~/.local に導入（binary + templates）
```

対象は macOS 14.0+ / Swift 5.10+。`Package.swift` に外部依存は無い（ライブビューアは
frame IPC で本体と話す。[ADR 0014](docs/decisions/0014-viewer-frame-ipc-drops-syphon-bundle.md)）。

**クローン直後に `make setup` を打ってください。** このリポジトリは `swift build` だけで
動くので setup を打つ動機が弱く、実際 `core.hooksPath` が未設定のまま
[クロスリポ契約](#cross-repo-contract)のチェックが CI 任せになっていた前例があります
（sibling の metaphor はサブモジュール初期化を伴うので自然に打たれる）。打ち忘れても
Claude Code のセッション開始時に `.claude/settings.json` の SessionStart フックが
同じ設定を入れます（設定済みなら何もしません）。

### CI が赤いまま終わらせない（Stop hook）

push しっぱなしで CI の赤に気付かないのを防ぐため、Claude Code のセッションが**赤い CI を残して終われない**ようにしています。`git push` を見たら見届け対象の印を置き、セッションを終えようとしたときに PR のチェック状況を見て、実行中なら見届けを促し、赤なら失敗ジョブ名とログ取得コマンドを添えて差し戻す Stop hook です（対象は自分の PR ブランチだけ。自動修正は 3 回・待機は 6 回で打ち切り、以降は人間の判断に返します）。

この仕掛けは**このリポジトリには同梱していません**。守る対象がリポジトリの構成ではなく Claude の振る舞いなので、開発者個人の Claude 環境（[shinyaoguri/claude-plugins](https://github.com/shinyaoguri/claude-plugins) の `repo-standards` プラグイン）が全プロジェクト向けに供給しています（経緯は同リポの [ADR 0016](https://github.com/shinyaoguri/claude-plugins/blob/main/docs/decisions/0016-agent-behavior-hooks-in-plugin.md)）。外部のコントリビュータの手元では動かないので、このリポジトリのセットアップとしては何も要りません。

差し戻されたときの直し方は通常のローカル検証と同じで、`make test`（契約に触れたなら `make contract` も）を通してから追加コミットしてください。

## Project Structure

3 つのモジュールに分かれています（`Package.swift` 参照）。

| モジュール | 役割 |
| --- | --- |
| `MetaphorCLI` | 薄いエントリポイント（`main.swift`）。`watch --viewer` を GUI へ、その他を Core へ振り分けるだけ。 |
| `MetaphorCLICore` | テスト可能なビジネスロジック。コマンド、watch セッション、MCP サーバ、テンプレート、リリース/更新、バイナリ解決。GUI 非依存。 |
| `MetaphorViewer` | GUI 層（AppKit / MetalKit）。ライブビューア窓、フレーム供給元（`FrameSource`。実装は frame IPC の `FrameIPCSource` = 共有メモリを `MTLBuffer(bytesNoCopy:)` で読む）、描画、状態オーバーレイ。 |
| `CMetaphorFrameIPC` | C シム。frame IPC のうち Swift から呼べない `shm_open` / `SCM_RIGHTS`（`sendmsg` / `recvmsg`）だけを包む。 |

`MetaphorCLICore` は副作用を `Console` / `ProcessRunning` / `ProcessLaunching` /
`FileWatching` / `SketchBinaryResolving` といったプロトコル越しに扱い、テストでモックを
注入できます（`Support.swift` に実装とモックの土台）。

ログの時刻表示は `TimestampedConsole`（`TimestampedConsole.swift`）という `Console`
デコレータで実現しており、**長時間動き続ける `watch` の 2 経路にだけ**被せています
（ビューア既定＝`main.swift`、`--no-viewer`＝`WatchCommand.swift`。どちらもヘルプ表示の
後に被せるので使い方テキストには付きません）。`new` / `doctor` のような一発実行
コマンドの整形済み出力には付けません。

### 主要ファイル

- コマンドルータ: `Commands.swift`（`CommandLineTool`）。各コマンドは
  `NewCommand.swift` / `RunCommand.swift` / `DoctorCommand.swift`
  （エディタ側の判定は `VSCodeEnvironment.swift` の純関数へ切り出し）/
  `WatchCommand.swift`（`Watch*`/`ProcessLaunching`/`FileWatching` に分割）/
  `UpdateCommand.swift` / `MCPCommand.swift`。
- watch コア: `WatchSession.swift`（ビルド→起動→再起動の制御）、`ProcessLaunching.swift`
  （非ブロッキング起動・stdin パイプ）、`FileWatching.swift`（監視の抽象 + ポーリング予備実装）、
  `FSEventsFileWatcher.swift`（既定の FSEvents 監視 + 安全ポーリング併走）。
- MCP: `MCP/MCPServer.swift`（stdio JSON-RPC ループ）、`MCP/MCPProtocol.swift`
  （`MCPToolHandling` / `MCPToolDefinition`）、`MCP/SketchToolHandler.swift`（公開ツールの
  定義と dispatch）。ファイル往復を伴うツールは個別クラスに分かれる:
  `MCP/ProbeSnapshotTool.swift` / `MCP/ProbeSequenceTool.swift`（契約点 4）、
  `MCP/ParameterStoreTool.swift`（契約点 7 = `params` / `set_param`）。いずれも
  「新しい `id` を書き、その id のエコーで ready を判定する」規約を共有する。
- metrics（`run`/`watch` の `--metrics`）: `Metrics/MetricsPoller.swift`（Probe ポーリング
  と MCP との競合調停）、`Metrics/MetricsReporter.swift`（整形とステータスライン表示）。

## Adding a New Command

1. `Sources/MetaphorCLICore/FooCommand.swift` に `FooCommand` struct を作る（依存は
   `Console` / `ProcessRunning` などプロトコルで受け取り、失敗は `CLIError` を throw）。
2. `Commands.swift` の `CommandLineTool.run(arguments:)` の `switch` に `case "foo":` を追加。
3. `CommandLineTool.helpText`（と必要なら各コマンドの `helpText`）を更新。
4. `Tests/MetaphorCLITests/` に、`BufferedConsole` / `RecordingProcessRunner` を使った
   テストを追加。

## Adding a New MCP Tool

MCP ツールは `MCPToolHandling`（`MCP/MCPProtocol.swift`）で表現されます。

1. `SketchToolHandler`（`MCP/SketchToolHandler.swift`）の `tools` に
   `MCPToolDefinition`（name / description / JSON Schema）を追加。
2. `call(name:arguments:)` の分岐に新ツールの処理を追加し、`MCPToolResult` を返す。
3. 子スケッチ側と新しい IPC（Probe ファイルや stdin JSON Lines）を増やす場合は、
   **両リポジトリの契約**になるため `CONTRACT.md` を更新し、`scripts/check-contract.sh`
   のトークンも合わせる（[CONTRACT.md](CONTRACT.md) と sibling リポジトリ参照）。
4. `Tests/MetaphorCLITests/SketchToolHandlerTests.swift` にテストを追加。

> stdout 保護: `MCPCommand.swift` は起動時に `dup2(2, 1)` で fd1 を stderr へ退避し、
> JSON-RPC 出力だけを本来の stdout に書きます。子プロセスのログが MCP 出力を汚さない
> ための仕掛けなので、MCP 経路で `print` を足すときは注意。

## Test Infrastructure

- `BufferedConsole`（`Support.swift`）: `output` / `errors` を配列に蓄積し、出力を検証。
- `RecordingProcessRunner`（`Support.swift`）: `run` 呼び出しを記録し、`result` で戻り値を差し替え。
- watch 系モック（`Tests/.../WatchSessionTests.swift`）: `RecordingLauncher` /
  `ManualFileWatcher`（`fireChange()` で変更を手動発火）/ `NullBinaryResolver`。

### 実スケッチのスモーク（`scripts/smoke-sketch.py`）

`swift test` と `check-templates.sh` が見ているのは「生成直後の雛形がビルドできる」までで、
**育った実物のスケッチを動かして初めて出る穴**は拾えません（#139 のリロード後にフレームが
来ない、#133 の `.metaphor/` の置き場は、どちらも人が作品を動かしていて偶然気付いたもの）。
そこを埋めるのがこのスモークで、[metaphor-sketches](https://github.com/shinyaoguri/metaphor-sketches)
の作品を 1 本取り出して実際に走らせます（Issue #153）。

```bash
swift build                                        # 先に CLI を建てる
python3 scripts/smoke-sketch.py                    # run + watch
python3 scripts/smoke-sketch.py --only watch       # ホットリロードだけ見る
python3 scripts/smoke-sketch.py --sketch-dir ~/work/my-sketch --keep
```

PASS の根拠は `.metaphor/probe/current/frame.json` の mtime です。このファイルは
`request.json` への**応答としてのみ**書かれる（CONTRACT.md 契約点 4）ので、
スモークは自分でリクエストを書かず `--metrics` を付けて **CLI 自身に書かせます**。
mtime が進む ＝ CLI → 子 → Probe → CLI の往復が生きている、という判定です。
watch 側はさらに「編集 → `[watch] リロードしました` → **その後に**新しいフレーム」まで
見ます（#139 と同じ症状を捕まえる要はこの順序で、リロード前のフレームを認めると
素通りします）。

CI では [`sketch-smoke.yml`](.github/workflows/sketch-smoke.yml) が持ちます。毎 PR では
回さず（metaphor 本体のフルビルドを伴うため分単位かかる）、`release.yml` から
`blocking: false` で呼ぶ ＝ **リリースのたびに走るがリリースは止めない**。手で回すときは
`gh workflow run sketch-smoke.yml`。

flaky になったときの調整点は、まずタイムアウト（`--build-timeout` / `--frame-timeout` /
`--reload-timeout`）、次に対象スケッチ（`--sketch`。依存が薄くビルドの速いものを選ぶ）。
窓を開けない環境では `--headless`（子へ `METAPHOR_VIEWER=1` = 契約点 5）に落とせます。

判定に関わる純ロジックは `scripts/tests/test_smoke_sketch.py` が固定していて、
CI の `python3 -m unittest discover -s scripts/tests` で毎 PR 走ります。スモーク本体が
重くて回らないぶん、**判定が緩む形の壊れ方**（古いフレームで PASS する等）はここで止めます。

### `BuildInfo` の値をテストで決め打ちしない

`release.yml` は **stamp / pin を済ませてから `swift test` を走らせる**（"Stamp version" →
"Pin default metaphor library version" → "Test"）。つまり `BuildInfo.version` は
タグの版、`BuildInfo.defaultMetaphorVersion` は metaphor の最新安定版、
`BuildInfo.isDevelopmentBuild` は **`false`** の状態でテストが走る。

PR の `build-and-test` は stamp も pin もしないので、**この 2 つは前提が違う**。
`isDevelopmentBuild` が真である前提や、版の文字列をリテラルで書いたテストは
**PR では緑、リリースだけ赤**になる（実例: #121 / #144）。期待値は `BuildInfo` の値から
組み立てるか、ビルド種別に依存する分岐は引数を取る純関数として切り出してテストする。

## Switching the metaphor used by `metaphor new` (direnv 推奨)

`metaphor new` などを実行するのが **brew で入れた安定版**（`/opt/homebrew/bin/metaphor`）
なのか、**このリポジトリのローカルビルド**（`.build/debug/metaphor`）なのかは、`PATH` 上で
どちらが先に見つかるかで決まります。毎回 `make install` / `make uninstall` で切り替えるのは
面倒なので、[direnv](https://direnv.net/) で自動化します。リポジトリには `.envrc` が同梱されており、
**このディレクトリ配下にいる間だけ** ローカルビルドを `PATH` 前方に差し込み、外に出れば自動で
brew 版に戻ります。`new` だけでなく `run` / `watch` / `doctor` など全コマンドが対象です。

> **テンプレートの出どころも変わります。** ローカル開発版の `metaphor new` はリポジトリの
> `Templates/` を直接読みます（`make install` でコピーした
> `~/.local/share/metaphor/templates` ではありません）。テンプレートを編集してすぐ試せます。

ビルド成果物は単体で動く（同梱物は無い）ので、`make install` を挟まずにライブビューア
（`watch --viewer`）も動きます。

初回セットアップ（一度だけ）:

```bash
brew install direnv
# シェルにフックを追加（zsh の場合）。bash/fish は direnv 公式手順を参照。
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc
exec $SHELL              # 新しいシェルを起動してフックを反映

cd ~/Repos/metaphor-cli
direnv allow             # 同梱の .envrc を許可（初回のみ）
swift build              # .build/debug/metaphor を生成
```

以降の開発ループ:

```bash
cd ~/Repos/metaphor-cli  # → 自動でローカル開発版に切替
swift build              # 変更を反映（次の metaphor 実行で即有効）
metaphor watch ...       # .build/debug/metaphor が動く

cd ~                     # → 自動で brew 版に戻る
```

- どちらが効いているか: `command -v metaphor` がパスを直接示す
  （`…/metaphor-cli/.build/debug/metaphor` ＝開発版、`/opt/homebrew/bin/metaphor` ＝brew 版）。
  `metaphor --version` の `-NN-gHASH` 付き＝開発版、`0.1.1` のようなクリーンなタグのみ＝brew 版。
- 既定は debug ビルド。release で確認したいときは `swift build -c release` 後に
  `METAPHOR_BUILD=release direnv allow`。
- `.build/debug` が未ビルドなら自動で brew 版にフォールバック。
- direnv を使う場合 `make install` は不要。

### 別の場所のプロジェクトをローカル開発版で作る・育てる

`~/Repos/metaphor-cli` の外（例: `~/Repos/test-meta`）を**ローカル開発版で**作って開発したい
ときは、そのプロジェクトにも同じ `.envrc` を置きます。作成（`metaphor new .`）から日常運用
（`run` / `watch`、`.mcp.json`）まで、ずっと同じローカル開発版で一貫します。

```bash
mkdir ~/Repos/test-meta && cd ~/Repos/test-meta
echo 'PATH_add "$HOME/Repos/metaphor-cli/.build/debug"' > .envrc
direnv allow                  # ここで `metaphor` がローカル開発版に確定
command -v metaphor           # → …/metaphor-cli/.build/debug/metaphor を確認

metaphor new .                # その同じ metaphor で初期化（テンプレは Templates/ から読まれる）
echo '.envrc' >> .gitignore   # マシン依存なのでコミットしない
metaphor watch                # 以降も同じローカル開発版で動く
```

> **順序がポイント。** 先に `.envrc` ＋ `direnv allow` を済ませてから `metaphor new .` します。
> 逆だと `~/Repos/test-meta` には `.envrc` が届かず、**作成だけ brew 版**になります。

## Templates

テンプレートは Swift コード内の文字列ではなく、`Templates/` 配下のファイルとして管理します。

```text
Templates/
  templates.json
  common/
    Package.swift.template
    README.md.template
    default.json.template
    vscode-tasks.json.template          # → .vscode/tasks.json
    vscode-extensions.json.template     # → .vscode/extensions.json
    vscode-settings.json.template       # → .vscode/settings.json
    sourcekit-lsp-config.json.template  # → .sourcekit-lsp/config.json
  2d/
    App.swift.template
  live/
    App.swift.template
```

ドットディレクトリへ配る生成物（`.vscode/` など）も、**ソース側はドット無しのフラットな名前**で
置きます（生成先は `templates.json` の `destination` が決めます）。生成先の親ディレクトリは
`NewCommand` が自動で作成します。

`templates.json` にテンプレートID・説明・生成ファイルを追加し、各 `.template` では次の
プレースホルダを使えます。

- `{{PROJECT_NAME}}`
- `{{PROJECT_NAME_SWIFT}}`
- `{{PROJECT_NAME_JSON}}`
- `{{MODULE_NAME}}`
- `{{TEMPLATE_ID}}`
- `{{METAPHOR_DEPENDENCY}}`
- `{{METAPHOR_PACKAGE_IDENTITY_SWIFT}}`

`make install` はテンプレートを `~/.local/share/metaphor/templates` にコピーします。別の
テンプレートセットを試す場合は `METAPHOR_TEMPLATES_PATH` を指定できます。

テンプレートの検索順（`templates.json` を最初に含んだ場所が勝ち）:

1. `METAPHOR_TEMPLATES_PATH`（明示オーバーライド）
2. 実行中のバイナリに隣接する `share/metaphor/templates`（symlink 解決前 → 解決後。
   brew は `/opt/homebrew/share/…`、direct installer は `~/.local/share/…` がここで解決される）
3. ソースチェックアウトの `Templates/`（`#filePath` 基準。ソースから実行したときに
   テンプレート編集を即試せる）
4. レガシー固定パス: `~/.local/share` → `/usr/local/share` → `/opt/homebrew/share`

旧インストール方式の残骸が、実行中のバイナリに同梱されたテンプレートを覆い隠さないよう、
バイナリ隣接（2）を固定パス（4）より優先しています（#69）。`metaphor new` と
`metaphor doctor` は使用したテンプレートの場所を表示します。

## Cross-Repo Contract

`metaphor` ↔ `metaphor-cli` は環境変数名・stdin 入力イベント・Probe ファイルパス・ライブビューアの
frame IPC・AI ドキュメントの場所などを共有契約として持ちます。詳細と変更ルールは [CONTRACT.md](CONTRACT.md)。

- `make contract` でトークン存在チェックと CONTRACT.md のクロスリポ同一性チェックを実行。
- 同じ 2 つを push 前に自動実行する pre-push フック（`scripts/hooks/pre-push`）を
  `make setup`（単体で入れるなら `make hooks`）が導入します。`core.hooksPath` が
  未設定だとフックは**黙って効かない**ので、`git config core.hooksPath` が
  `scripts/hooks` を返すことで有効化を確認できます。

## Release / Homebrew

リリース手順と Homebrew formula のデプロイは [docs/homebrew.md](docs/homebrew.md) を参照。
