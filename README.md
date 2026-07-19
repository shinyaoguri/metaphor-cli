# metaphor-cli

[![Release](https://img.shields.io/github/v/release/shinyaoguri/metaphor-cli?label=version)](https://github.com/shinyaoguri/metaphor-cli/releases/latest)
[![CI](https://github.com/shinyaoguri/metaphor-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/shinyaoguri/metaphor-cli/actions/workflows/ci.yml)
[![Platform macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**スケッチの作成・実行・ライブリロード・AI 協調を 1 つの `metaphor` コマンドで。**

`metaphor-cli` は、Swift + Metal クリエイティブコーディングライブラリ [`metaphor`](https://github.com/shinyaoguri/metaphor) のための開発者向けコマンドです。

```bash
brew install shinyaoguri/tap/metaphor
metaphor new MySketch
cd MySketch
metaphor run
```

## コマンド一覧

| コマンド | 役割 |
|---|---|
| `metaphor new <name>` | テンプレートから SwiftPM ベースのスケッチプロジェクトを作成（`.` で既存ディレクトリを初期化） |
| `metaphor init` | `metaphor new .` のエイリアス |
| `metaphor run` | 現在のスケッチを実行（解決・ビルド・ウィンドウ表示までまとめて） |
| `metaphor watch` | ソース変更を監視し、ライブビューア窓を保ったまま再ビルド差し替え |
| `metaphor mcp` | AI エージェント向け MCP サーバ（[AI と協調する](#ai-と協調する)） |
| `metaphor update` | CLI 本体と `metaphor` ライブラリの更新を確認・適用 |
| `metaphor doctor` | Swift / Xcode / テンプレート / Syphon 環境の診断 |
| `metaphor examples` | 利用できるテンプレートの一覧表示 |
| `metaphor version` | バージョン表示 |

生成されるプロジェクトは通常の Swift Package なので、`swift run` でも実行できます。また、AI アシスタント向けの `AGENTS.md`（＋ Claude Code 向けに `@AGENTS.md` を import する薄い `CLAUDE.md`）と、制作意図を短く保つ `PROJECT_BRIEF.md` が同梱され、どの AI クライアントでも同じガイドが自動でコンテキストに載ります。

## テンプレート

`metaphor new <name> --template <id>` で選択します（省略時は `2d`）。

| ID | 内容 | こんなときに |
|---|---|---|
| `2d` | 最小の Processing 風 2D スケッチ | 最初の 1 本・2D 主体の作品 |
| `3d` | カメラ・ライト・アニメーションする 3D プリミティブ | 3D 空間・カメラワーク |
| `shader` | カスタム Metal ポストプロセスシェーダ付きスケッチ | 独自の Metal シェーダ表現を書きたい |
| `live` | ライブパフォーマンス全部入り: パラメータ GUI・OSC 入力・MIDI 入力・Performance HUD | VJ・ライブ演出・外部機器からの操作 |
| `audio-reactive` | マイク入力の FFT 解析でビジュアルを駆動 | 音に反応する作品 |
| `raytracing` | MPS / Metal レイトレーシングのスターターシーン | レイトレーシング表現 |
| `syphon` | Syphon 出力向けの固定解像度スケッチ | MadMapper / Resolume 等へ映像を送る |

```bash
metaphor examples                      # 一覧を確認
metaphor new LiveSet --template live
cd LiveSet
metaphor run
```

## Requirements

- Apple Silicon Mac / macOS 14+
- Xcode 15+ / Swift 5.10+
- Git

## Install

### Homebrew（推奨）

リポジトリを clone する必要はありません。

```bash
brew install shinyaoguri/tap/metaphor
```

確認と更新:

```bash
metaphor doctor
brew upgrade metaphor
```

以前に direct installer や `make install` で `~/.local/bin/metaphor` を入れていた場合、Homebrew 版より先に見つかることがあります。その場合は古いバイナリを削除するか、`PATH` の順序を調整してください。バイナリだけでなくテンプレート（`~/.local/share/metaphor`）も残るため、まとめて削除するのが安全です。

```bash
rm -f ~/.local/bin/metaphor
rm -rf ~/.local/libexec/metaphor
rm -rf ~/.local/share/metaphor
```

### Direct Installer

Homebrew を使わない場合は、最新リリースのバイナリを直接インストールできます。

```bash
curl -fsSL https://raw.githubusercontent.com/shinyaoguri/metaphor-cli/main/scripts/install.sh | bash
```

`~/.local/bin` が `PATH` に入っていない場合は追加してください（zsh の例）:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

インストール先を変える場合は `PREFIX=/usr/local` を付けます。direct installer は `metaphor` 本体と Syphon.framework を `~/.local/libexec/metaphor/` に置き、`~/.local/bin/metaphor` をそこへのシンボリックリンクとして張ります（Syphon を `@loader_path` で解決させるため）。アンインストールは次を削除します。

```bash
rm -f ~/.local/bin/metaphor
rm -rf ~/.local/libexec/metaphor
rm -rf ~/.local/share/metaphor/templates
```

### ソースからインストール

開発版を使う場合や CLI 自体を変更したい場合だけ、リポジトリを clone します。

```bash
git clone https://github.com/shinyaoguri/metaphor-cli.git
cd metaphor-cli
make install          # ~/.local/bin/metaphor と ~/.local/share/metaphor/templates を配置
```

`make install PREFIX=/usr/local` で配置先を変更、`make uninstall` で削除できます。

### ローカルの metaphor checkout を参照する

生成したスケッチからローカル checkout の `metaphor` ライブラリを参照したい場合:

```bash
git clone --recursive https://github.com/shinyaoguri/metaphor.git ~/Repos/metaphor
metaphor new MySketch --template live --metaphor-path ~/Repos/metaphor
```

`--metaphor-path` を指定しない場合は、GitHub Releases の最新 `metaphor` バージョンを参照する `Package.swift` が生成されます。

## Commands

### `metaphor new`

```bash
metaphor new MySketch                  # カレント直下に MySketch/ を作成
metaphor new MyScene --template 3d
```

テンプレートは `--template <id>` で選びます（[テンプレート](#テンプレート)参照、省略時は `2d`）。名前の代わりに `.` を渡すと、既存ディレクトリの中でそのまま初期化します（[`metaphor init`](#metaphor-init) と同じ）。そのほかのオプション（`--metaphor-path` / `--git` / `--no-resolve` など）は `metaphor new --help` を参照してください。

### `metaphor init`

`metaphor new .` のエイリアスです。`new <name>` が新しいディレクトリを作るのに対し、`init` は**いまいるディレクトリを in-place でスケッチ化**します。プロジェクト名はフォルダ名から取られます（`test-meta/` → Package 名 `test-meta` / モジュール `TestMeta`）。

```bash
mkdir test-meta && cd test-meta
metaphor init                          # = metaphor new .
metaphor init --template live          # オプションは new と共通
```

`.envrc` や `.git` が既にあっても構いません。生成しようとしたファイルが既に存在して衝突するときだけ、上書きの明示として `--force` が必要です。

### `metaphor run`

現在のディレクトリのスケッチを実行します（依存解決・ビルド・ウィンドウ表示までまとめて）。

```bash
metaphor run                     # 実体は swift run
metaphor run --syphon            # 出力を Syphon ソースとして publish（名前はディレクトリ名から）
metaphor run --syphon=MyOutput   # publish する Syphon サーバー名を明示
metaphor run --fps 30            # レンダー FPS を上書き（既定: スケッチの config.fps）
metaphor run --metrics           # fps・メモリ・CPU 等をターミナルへライブ表示
metaphor run -c release          # 専用フラグ以外は swift run へそのまま転送
```

- `--syphon[=name]` — スケッチの出力を Syphon ソースとして公開し、MadMapper / Resolume / VDMX などの映像ツールから読めるようにします（子プロセスに `METAPHOR_SYPHON_NAME` を設定）。
- `--fps <n>` — レンダー FPS を上書きします（子プロセスに `METAPHOR_FPS` を設定）。
- `--metrics` — 実測 fps・フレーム時間・メモリ・CPU・thermal をターミナル最下行へライブ表示します（下記参照）。
- 上記以外の引数は**そのまま `swift run` へ転送**されます。`-c release`（release ビルドで実行）など、`swift run` のオプションがそのまま使えます。

### `metaphor watch`

ソース（`Sources/**/*.swift`, `Package.swift`）を監視し、保存のたびに再ビルドします。

```bash
metaphor watch              # 既定: ライブビューア窓を保ったまま、子スケッチだけ差し替え
metaphor watch --no-viewer  # スケッチ自身のウィンドウを再起動する従来モード
metaphor watch --syphon-name MySketch  # publish する Syphon サーバー名を固定
metaphor watch --no-probe   # AI からの観測（共有セッション）を無効化
metaphor watch --fps 30     # レンダー FPS を上書き（既定: スケッチの config.fps）
metaphor watch --metrics    # fps・メモリ・CPU 等をターミナルへライブ表示
metaphor watch -c release   # 専用フラグ以外は swift build / swift run へそのまま転送
```

既定（ビューア）では常設のライブビューア窓を開き、再ビルド時はスケッチ（子プロセス）だけを差し替えます。ウィンドウは閉じず、マウス/キー入力はビューアからスケッチへ転送されます。既定で AI からアタッチ観測できる共有セッションも公開します（[AI と協調する](#ai-と協調する)）。

`run` と同様、上記の専用フラグ以外の引数は再ビルド・実行の全経路（`swift build`、フォールバック時の `swift run`）へそのまま転送されます。`metaphor watch -c release` で release ビルドのままライブリロードできます。

#### `--metrics` — パフォーマンスのライブ表示

`run` / `watch` 共通のオプションです。スケッチの「重い/軽い」を AI（MCP）を介さずその場で確認できます。

```
fps 59.8/60 │ frame 4.2ms (max 9.1) │ mem 141MB │ cpu 23% │ thermal nominal
```

- 子プロセスへ `METAPHOR_PROBE=1` を自動注入し、Probe の `performance` セクション（metaphor 0.7.0+）を定期ポーリングしてターミナル最下行に上書き表示します（リダイレクト時は変化があったときだけ 1 行ずつログ）。
- `--metrics-interval <秒>` でポーリング間隔を変更できます（既定 1 秒、下限 0.2 秒。指定すると `--metrics` は省略可）。
- fps はビルド構成に強く依存します（debug と release で数倍差が出ます）。パフォーマンス判断は `-c release` と組み合わせるのがおすすめです。
- `noLoop()` で停止中のスケッチは Probe リクエストを処理しないため、「応答待ち」表示になります。
- `metaphor mcp` の `snapshot` / `capture_sequence` と同じ Probe チャネルを使いますが、MCP 側のリクエストを優先して譲るため併用できます。

### `metaphor mcp`

AI エージェント向けの MCP サーバ（JSON-RPC / stdio）です。AI と協調させる＝この MCP を使う、ということなので、**最初に 1 度だけ次を実行して登録します**。

```bash
claude mcp add metaphor -- metaphor mcp .
```

登録後は、AI クライアント（Claude Code / Cursor 等）が必要なときに `metaphor mcp` を裏で自動的に起動・終了します。**自分で `metaphor mcp` をターミナルから打つことはありません**（`metaphor run` / `metaphor watch` のような手動実行コマンドとは役割が違います）。`.mcp.json` での共有や全体の流れは [AI と協調する](#ai-と協調する) を参照してください。

> 参考: サーバ単体の起動形は `metaphor mcp [sketch-dir]`（省略時はカレントディレクトリ）。動作確認やデバッグ以外で直接使うことはありません。

### `metaphor update`

```bash
metaphor update          # 更新確認
metaphor update self     # direct installer で入れた CLI 本体を GitHub Releases から更新
metaphor update library  # 現在の Swift package 内で metaphor ライブラリ解決を更新
```

Homebrew でインストールした場合、CLI 本体の更新は Homebrew に任せます（`brew upgrade metaphor`）。Homebrew 管理下で `metaphor update self` を実行した場合は、CLI が自身を直接上書きせず `brew upgrade metaphor` を案内します。

#### 新バージョンの自動通知

コマンド実行時、新しいリリースが出ていれば stderr に 1〜2 行のヒントが表示されます。チェックはローカルキャッシュ（`~/.cache/metaphor/update-check.json`）ベースで、ネットワークへは 24 時間に 1 回だけコマンドの裏で問い合わせるため、コマンドの実行を待たせることはありません。`metaphor mcp`（stdio プロトコル）・非対話実行（スクリプト / CI）・ローカル開発ビルドでは表示されません。無効化する場合は環境変数 `METAPHOR_NO_UPDATE_CHECK=1` を設定します。

### `metaphor doctor`

開発環境をまとめて診断し、項目ごとに `[ok]` / `[warn]` を表示します。何かうまく動かないとき・バグ報告するときに最初に実行してください（[Troubleshooting](#troubleshooting) / [フィードバック](#フィードバック--issue-報告)）。

```console
$ metaphor doctor
metaphor doctor
[ok] Swift: Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
[ok] Xcode: Xcode 26.6
[ok] Package.swift found
[ok] 7 project templates available (/opt/homebrew/Cellar/metaphor/0.4.0/share/metaphor/templates)
[ok] Syphon.framework loaded: /opt/homebrew/Cellar/metaphor/0.4.0/libexec/Syphon.framework/Versions/A/Syphon
```

診断項目は、Swift / Xcode のバージョン、カレントディレクトリの `Package.swift` の有無（スケッチ外で実行すると `[warn]`）、プロジェクトテンプレートの配置、Syphon.framework のロード元です。`[warn]` の項目に対応する機能（テンプレート生成、ライブビューア / Syphon 出力など）が使えない状態を示します。

### `metaphor examples`

利用できるテンプレートの一覧を表示します。

```console
$ metaphor examples
Available templates:
  2d               Minimal Processing-style 2D sketch.
  3d               Camera, lights, and animated 3D primitives.
  shader           Sketch with a custom Metal post-process effect.
  live             Parameter GUI, OSC input, MIDI input, and performance HUD.
  audio-reactive   Microphone FFT analysis driving visuals.
  raytracing       MPS/Metal ray tracing starter scene.
  syphon           Fixed-resolution output configured for Syphon.

Example:
  metaphor new MySketch --template live
```

各テンプレートの内容と選び方のガイドは [テンプレート](#テンプレート) を参照してください。

## AI と協調する

`metaphor` は AI エージェント（Claude Code / Cursor など）が**実行中のスケッチを観測しながら**開発できるように作られています。`metaphor mcp` を MCP サーバとして登録すると、エージェントは**レンダリング結果の画像と内部状態**を取得し、再ビルドの結果まで確認しながら「観測 → 編集 → 再観測 → 検証」を自律的に反復できます。

> 観測の仕組み（**Probe**）と設計の背景は metaphor 本体側にあります:
> [ai-mcp-server.md](https://github.com/shinyaoguri/metaphor/blob/main/docs/design/ai-mcp-server.md) /
> [shared-session.md](https://github.com/shinyaoguri/metaphor/blob/main/docs/design/shared-session.md)。

### 公開ツール

| ツール | 役割 |
|---|---|
| `snapshot` | 現在フレームの画像（PNG）と内部状態（`frameCount` / `time` / `probe()` 値 / 色・領域統計 / 実測パフォーマンス / 警告）を返す |
| `capture_sequence` | 連続フレーム列を採取し、コンタクトシート画像とフレーム別 manifest を返す（動き・リズム・遷移を観測する） |
| `input` | 実行中のスケッチへマウス・キー入力を送る（単独モードのみ） |
| `build_status` | 直近の `swift build` の成否とエラーを返す |
| `api_reference` | 依存先 metaphor の API ドキュメント（作法ガイド / 全 API / サンプル索引）を返す |

スケッチの性能診断（重い/軽い・どれくらい重いか）は、`snapshot` が返す `performance`
（実測 `fps` / `targetFPS` / `frameTimeMs` / `memoryMB` / `cpuPercent` / `thermalState`）で
画像に頼らず判定できます。フィールド定義は [CONTRACT.md](CONTRACT.md) を参照。

### セットアップ

1. スケッチを作成する。

   ```bash
   metaphor new MySketch
   cd MySketch
   ```

2. **最初に 1 度だけ、MCP サーバを登録します。** Claude Code では、スケッチのディレクトリで次を実行します。

   ```bash
   claude mcp add metaphor -- metaphor mcp .
   ```

   リポジトリで共有する場合は、スケッチ直下に `.mcp.json` を置きます（Claude Code / Cursor / VS Code が同一形式を読みます）。

   ```json
   {
     "mcpServers": {
       "metaphor": { "type": "stdio", "command": "metaphor", "args": ["mcp", "."] }
     }
   }
   ```

   登録後は、AI クライアントが必要なときに `metaphor mcp` を裏で自動的に起動・終了します。自分でターミナルから打つ必要はありません。

3. エージェントに依頼する。同じディレクトリで AI クライアントを開き、目的を伝えます。エージェントは `snapshot` で結果を確認しながらコードを修正します。

   > 例: 「円を画面中央でゆっくり回転させて。`snapshot` で確認しながら調整して。」

### 仕組み

```
   ┌──────────────────────────────────────────────┐
   │  AI エージェント（Claude Code / Cursor / …）     │
   └──────────────────────────────────────────────┘
        │  MCP (JSON-RPC 2.0 / stdio) ※クライアントが自動起動
        ▼
   ┌──────────────────────────────────────────────┐
   │  metaphor mcp .   （ヘッドレスでスケッチを実行）   │
   │  ・snapshot / capture_sequence  観測           │
   │  ・input                        操作           │
   │  ・build_status                 検証           │
   │  ・api_reference                API 参照       │
   └──────────────────────────────────────────────┘
        │
        ▼
   観測 ──→ 編集 ──→ 再観測 ──→ 検証 ──┐
     ▲                              │
     └──────────────────────────────┘
```

### 人間と AI で同じスケッチを共有する（共有セッション）

VSCode でコードを編集しながら、同じ実行中スケッチを AI にも観測させたい場合は、ターミナルで `metaphor watch` を起動しておきます。

```bash
metaphor watch        # ライブビューア窓を開き、共有セッションを公開する
```

この状態で AI クライアント（MCP 登録済み）から依頼すると、`metaphor mcp` は**新しくスケッチを起動せず、動作中の `watch` セッションにアタッチ**して観測します。編集は人間（VSCode）も AI（ファイルを直接編集）もディスクに書くだけで、`watch` が再ビルドして両者へ反映されます。

> **起動の順序に注意。** `metaphor mcp` が「動作中の `watch` にアタッチするか／自前で別インスタンスを起動するか」を決めるのは、**起動した瞬間に 1 度だけ**です（`.metaphor/session.json` の生存 pid を確認する）。`metaphor mcp` を起動するのは Claude Code なので、**先に `metaphor watch` を立ててから Claude Code を開いてください**。
>
> 逆順（Claude Code を先に開き `metaphor mcp` が起動済み）だと、mcp は `watch` を見つけられず**自前の別インスタンス**（ヘッドレス）を観測し、あなたのビューア窓とは別物になります。後から再チェックはしません。直すには Claude Code 側で MCP を再接続（`/mcp`）するか開き直すと、`metaphor mcp` が再起動して `watch` にアタッチし直します。

一度この形にすれば、登録は最初の 1 回きりで、あとは `metaphor watch` を動かしておくだけで Claude Code から `snapshot` でいつでも観測できます。

| 用途 | 必要なターミナル | 表示 | 起動方法 |
|---|---|---|---|
| AI 主導（MCP のみ） | 不要 | ヘッドレス（AI が `snapshot` で観測） | AI クライアントがサーバを自動起動 |
| 人間によるライブ編集 | 1 | ライブビューア窓 | `metaphor watch` を手動実行 |
| 人間 ＋ AI の協調（共有セッション） | 1 | ライブビューア窓 | `metaphor watch`（人間）＋ MCP（AI が自動起動） |

- ビルドの所有者は `watch` 1 つだけなので、ビルドの競合は起きません。
- AI は `snapshot` でライブビューアと同じ実体を観測し、`build_status` でビルドの成否を確認します。
- 操作は人間・AI ともにコード編集で行います（共有セッションに AI からの入力注入はありません）。
- 共有を無効にするには `metaphor watch --no-probe` で起動します。

## Development

CLI 本体を開発する手順（ビルド/テスト、プロジェクト構成、direnv によるローカル版/brew 版の切り替え、新規コマンド・MCP ツールの追加、テンプレート編集、クロスリポ契約）は **[DEVELOPMENT.md](DEVELOPMENT.md)** にまとめています。

```bash
swift build && swift test    # ビルド & テスト
swift run metaphor --help    # ローカルビルドを直接実行
make install                 # release ビルドを ~/.local に導入
```

AI エージェントで作業する場合の起点は [AGENTS.md](AGENTS.md)、metaphor 本体とのクロスリポ契約は [CONTRACT.md](CONTRACT.md) です。

## Troubleshooting

まず [`metaphor doctor`](#metaphor-doctor) を実行すると、Swift / Xcode / テンプレート / Syphon.framework の状態がまとめて確認できます。

- **`metaphor watch` のビューア窓が黒いまま** — 子スケッチの初回ビルド中か、ビルド失敗の可能性。ターミナルの `[watch]` ログを確認してください。ビルド失敗時は直前のスケッチを維持し、`[watch] ビルド失敗 …` を表示します。
- **`metaphor watch` が遅い／毎回フルビルドになる** — バイナリ解決に失敗すると `swift run` にフォールバックします。`[watch] バイナリ解決に失敗 …` が出る場合は、パッケージに executable プロダクトがあるか、`swift build --show-bin-path` が通るか確認。
- **AI（MCP）から観測できない** — `metaphor watch`（共有セッション）が起動しているか、`metaphor watch --no-probe` で無効化していないかを確認。`metaphor mcp` は同じディレクトリで実行します。詳細は [AI と協調する](#ai-と協調する) を参照。
- **`metaphor` がローカル開発版か brew 版か分からない** — `command -v metaphor` で実体パスを確認。direnv の設定は [DEVELOPMENT.md](DEVELOPMENT.md) を参照。
- **`metaphor update` が固まる** — GitHub への通信待ち（最大 60 秒でタイムアウト）。ネットワーク到達性を確認してください。Homebrew 導入版は `brew upgrade` を案内します。

## フィードバック / Issue 報告

metaphor-cli はまだ発展途上です。問題や改善のアイデアを見つけたら、小さなことでも**気軽に [Issues](https://github.com/shinyaoguri/metaphor-cli/issues) へ報告・提案してください**。「この説明が分かりにくい」「エラーメッセージが不親切」「こんなテンプレートが欲しい」といった声も歓迎です。

バグ報告には次があると助かります:

- `metaphor doctor` の出力（環境情報がまとまっています）
- 実行したコマンドと、そのときのターミナル出力（`[watch]` ログなど）
- 期待した動作と実際の動作

描画やライブラリ API に関する問題は [metaphor 本体の Issues](https://github.com/shinyaoguri/metaphor/issues) へ。どちらか迷ったら、こちら（metaphor-cli）に立ててもらえれば適切に振り分けます。

AI エージェント経由で使っている場合も同様です — エージェントに「この問題を GitHub Issue として報告して」と頼めば、再現手順つきで起票できます。
