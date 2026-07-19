# metaphor-cli Development

このドキュメントは `metaphor-cli`（CLI ツール本体）を開発する人向けです。

CLI の使い方は [README.md](README.md) を参照してください。`metaphor` ライブラリ本体の開発は、
sibling リポジトリ [shinyaoguri/metaphor](https://github.com/shinyaoguri/metaphor) の
`DEVELOPMENT.md` を参照してください。

## Build & Test

```bash
swift build               # デバッグビルド
swift test                # テスト実行
swift run metaphor --help # ローカルビルドを直接実行
make release              # リリースビルド
make install              # release ビルドを ~/.local に導入（Syphon.framework 同梱）
```

対象は macOS 14.0+ / Swift 5.10+。外部依存は Syphon.xcframework のみ（`Package.swift` で
GitHub Release からピン留め取得、checksum 検証あり）。

## Project Structure

3 つのモジュールに分かれています（`Package.swift` 参照）。

| モジュール | 役割 |
| --- | --- |
| `MetaphorCLI` | 薄いエントリポイント（`main.swift`）。内部コマンド（`__view` / `__capture`）と `watch --viewer` を GUI へ、その他を Core へ振り分けるだけ。 |
| `MetaphorCLICore` | テスト可能なビジネスロジック。コマンド、watch セッション、MCP サーバ、テンプレート、リリース/更新、バイナリ解決。GUI 非依存。 |
| `MetaphorViewer` | GUI 層（AppKit / MetalKit / Syphon）。ライブビューア窓、Syphon フレーム取得、描画、状態オーバーレイ。 |

`MetaphorCLICore` は副作用を `Console` / `ProcessRunning` / `ProcessLaunching` /
`FileWatching` / `SketchBinaryResolving` といったプロトコル越しに扱い、テストでモックを
注入できます（`Support.swift` に実装とモックの土台）。

### 主要ファイル

- コマンドルータ: `Commands.swift`（`CommandLineTool`）。各コマンドは
  `NewCommand.swift` / `RunCommand.swift` / `DoctorCommand.swift` /
  `WatchCommand.swift`（`Watch*`/`ProcessLaunching`/`FileWatching` に分割）/
  `UpdateCommand.swift` / `MCPCommand.swift`。
- watch コア: `WatchSession.swift`（ビルド→起動→再起動の制御）、`ProcessLaunching.swift`
  （非ブロッキング起動・stdin パイプ）、`FileWatching.swift`（ポーリング監視）。
- MCP: `MCP/MCPServer.swift`（stdio JSON-RPC ループ）、`MCP/MCPProtocol.swift`
  （`MCPToolHandling` / `MCPToolDefinition`）、`MCP/SketchToolHandler.swift`（4 ツール実装）。

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

ビルド成果物は `Syphon.framework` が隣接し `@loader_path` で解決されるため、`make install` の
ような rpath 付与・再署名なしでライブビューア（`watch --viewer`）も動きます。

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
  2d/
    App.swift.template
  live/
    App.swift.template
```

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

`metaphor` ↔ `metaphor-cli` は環境変数名・stdin 入力イベント・Probe ファイルパス・Syphon 名・
AI ドキュメントの場所などを共有契約として持ちます。詳細と変更ルールは [CONTRACT.md](CONTRACT.md)。

- `make contract` でトークン存在チェックと CONTRACT.md のクロスリポ同一性チェックを実行。
- `make hooks` で pre-push フックを導入すると、push 前に上記を自動チェックします。

### Syphon pin bump PR の処理手順

`Package.swift` の Syphon.xcframework pin(契約点 1)は、週次ポーリング(`syphon-bump.yml`、毎週月曜)が
metaphor の新リリースを検出して bump PR を自動作成します。metaphor のリリース直後に手動で起動することもできます:

```bash
gh workflow run "Bump Syphon pin" -R shinyaoguri/metaphor-cli
```

**bot 作成の PR は CI が発火しません**(GITHUB_TOKEN 起点のイベントは再帰防止のため `pull_request`
workflow をトリガーしない、という GitHub Actions の仕様)。required check(build-and-test)を
揃えるには、PR を **close → reopen** してください(自分のアカウント起点の reopened イベントで
正規の CI が走ります。`gh workflow run CI --ref <branch>` では required check として認識されません)。
その後 CI green を確認して squash merge します。

滞留自体を無くす恒久策(fine-grained PAT 化など)の検討経緯は
[#78](https://github.com/shinyaoguri/metaphor-cli/issues/78) を参照。リリース頻度が低い間は
本手順(close→reopen)で受容する判断です。

## Release / Homebrew

リリース手順と Homebrew formula のデプロイは [docs/homebrew.md](docs/homebrew.md) を参照。
