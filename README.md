# metaphor-cli

`metaphor-cli` は、Swift + Metal クリエイティブコーディングライブラリ
[`metaphor`](https://github.com/shinyaoguri/metaphor) のための開発者向けコマンドです。

新しいスケッチの作成、テンプレート選択、実行、環境確認、CLI本体と `metaphor`
ライブラリの更新を、`metaphor` コマンドから扱えるようにします。

```bash
metaphor new MySketch
cd MySketch
metaphor run
```

## What It Does

- `metaphor new` で SwiftPM ベースのスケッチプロジェクトを作成
- `2d`、`3d`、`shader`、`live`、`audio-reactive`、`raytracing`、`syphon` テンプレートを提供
- 生成プロジェクトに `AGENTS.md` と `PROJECT_BRIEF.md` を含め、AI と制作意図を共有しやすくする
- `metaphor run` で現在のスケッチを実行
- `metaphor watch` でソース変更を監視し、ライブビューア窓を保ったまま再ビルド差し替え
- `metaphor mcp` で AI エージェント（Claude Code / Cursor 等）向けの MCP サーバを提供し、実行中のスケッチを観測させる（[AI と協調する](#ai-と協調する)）
- `metaphor doctor` で Swift / Xcode / テンプレート環境を確認
- `metaphor update` で CLI と `metaphor` ライブラリの更新を確認・適用

## Quick Start

```bash
brew install shinyaoguri/tap/metaphor
metaphor new MySketch
cd MySketch
metaphor run
```

テンプレートを選ぶ場合:

```bash
metaphor examples
metaphor new LiveSet --template live
cd LiveSet
metaphor run
```

生成されるプロジェクトは通常の Swift Package なので、`swift run` でも実行できます。
また、生成プロジェクトには AI アシスタント向けの `AGENTS.md` と、制作意図を短く保つ
`PROJECT_BRIEF.md` が含まれます。
Homebrew を使わない導線は [Install](#install) を参照してください。

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.10+
- Git

## Install

### Homebrew

通常の利用では Homebrew を推奨します。リポジトリを clone する必要はありません。

```bash
brew install shinyaoguri/tap/metaphor
```

確認:

```bash
metaphor version
metaphor --help
metaphor doctor
```

更新:

```bash
brew upgrade metaphor
```

以前に direct installer や `make install` で `~/.local/bin/metaphor` を入れていた場合、
Homebrew 版より先に見つかることがあります。その場合は古いバイナリを削除するか、
`PATH` の順序を調整してください。

```bash
rm -f ~/.local/bin/metaphor
```

### Direct Installer

Homebrewを使わない場合は、最新リリースのバイナリを直接インストールできます。

```bash
curl -fsSL https://raw.githubusercontent.com/shinyaoguri/metaphor-cli/main/scripts/install.sh | bash
```

`~/.local/bin` が `PATH` に入っていない場合は追加してください。

zsh:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

bash:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

確認:

```bash
command -v metaphor
metaphor version
metaphor --help
metaphor doctor
```

インストール先を変える場合:

```bash
curl -fsSL https://raw.githubusercontent.com/shinyaoguri/metaphor-cli/main/scripts/install.sh | PREFIX=/usr/local bash
```

アンインストールはインストールされたファイルを削除します。

```bash
rm -f ~/.local/bin/metaphor
rm -rf ~/.local/share/metaphor/templates
```

## Install From Source

開発版を使う場合やCLI自体を変更したい場合だけ、リポジトリを clone します。

```bash
mkdir -p ~/Repos
cd ~/Repos
git clone git@github.com:shinyaoguri/metaphor-cli.git
cd metaphor-cli
make install
```

HTTPSを使う場合:

```bash
git clone https://github.com/shinyaoguri/metaphor-cli.git
```

`make install` は次の2つを配置します。

```text
~/.local/bin/metaphor
~/.local/share/metaphor/templates
```

インストール先を変える場合:

```bash
make install PREFIX=/usr/local
```

アンインストール:

```bash
make uninstall
```

## Local metaphor Checkout

生成したスケッチからローカル checkout の `metaphor` ライブラリを参照したい場合:

```bash
cd ~/Repos
git clone --recursive git@github.com:shinyaoguri/metaphor.git
metaphor new MySketch --template live --metaphor-path ~/Repos/metaphor
cd MySketch
metaphor run
```

`--metaphor-path` を指定しない場合は、GitHub Releases の最新 `metaphor`
バージョンを参照する `Package.swift` が生成されます。

## Commands

```bash
metaphor new <name>
metaphor init
metaphor run
metaphor watch
metaphor mcp
metaphor update
metaphor doctor
metaphor examples
metaphor version
```

### `metaphor new`

```bash
metaphor new MySketch                  # カレント直下に MySketch/ を作成
metaphor new MyScene --template 3d
metaphor new LiveSet --template live
metaphor new ShaderLab --template shader
```

すでにあるディレクトリの中で初期化したいときは、名前の代わりに `.` を渡します。
プロジェクト名はそのフォルダ名から取られます（`test-meta/` → Package 名 `test-meta` /
モジュール `TestMeta`）。`.envrc` や `.git` が既にあっても構いません（既存の生成物を
上書きするときだけ `--force` が必要）。

```bash
mkdir test-meta && cd test-meta
metaphor new .                         # = metaphor init
metaphor init --template live          # init は `new .` のエイリアス
```

### `metaphor watch`

ソース（`Sources/**/*.swift`, `Package.swift`）を監視し、保存のたびに再ビルドします。

```bash
metaphor watch              # 既定: ライブビューア窓を保ったまま、子スケッチだけ差し替え
metaphor watch --no-viewer  # スケッチ自身のウィンドウを再起動する従来モード
metaphor watch --syphon-name MySketch  # publish する Syphon サーバー名を固定
metaphor watch --no-probe   # AI からの観測（共有セッション）を無効化
```

既定（ビューア）では常設のライブビューア窓を開き、再ビルド時はスケッチ（子プロセス）だけを差し替えます。ウィンドウは閉じず、マウス/キー入力はビューアからスケッチへ転送されます。既定で AI からアタッチ観測できる共有セッションも公開します（[AI と協調する](#ai-と協調する)）。

### `metaphor mcp`

AI エージェント向けの MCP サーバ（JSON-RPC / stdio）です。AI と協調させる＝この MCP を使う、ということなので、**最初に 1 度だけ次を実行して登録します**。

```bash
claude mcp add metaphor -- metaphor mcp .
```

登録後は、AI クライアント（Claude Code / Cursor 等）が必要なときに `metaphor mcp` を裏で自動的に起動・終了します。**自分で `metaphor mcp` をターミナルから打つことはありません**（`metaphor run` / `metaphor watch` のような手動実行コマンドとは役割が違います）。`.mcp.json` での共有や全体の流れは [AI と協調する](#ai-と協調する) を参照してください。

> 参考: サーバ単体の起動形は `metaphor mcp [sketch-dir]`（省略時はカレントディレクトリ）。動作確認やデバッグ以外で直接使うことはありません。

### `metaphor update`

更新確認:

```bash
metaphor update
```

direct installer で入れたCLI本体を GitHub Releases から更新:

```bash
metaphor update self
```

Homebrew でインストールした場合、CLI本体の更新は Homebrew に任せます。

```bash
brew upgrade metaphor
```

Homebrew 管理下で `metaphor update self` を実行した場合は、CLIが自身を直接上書きせず
`brew upgrade metaphor` を案内します。

現在の Swift package 内で `metaphor` ライブラリ解決を更新:

```bash
metaphor update library
```

## AI と協調する

`metaphor` は AI エージェント（Claude Code / Cursor など）が **実行中のスケッチを観測しながら** 開発できるように作られています。`metaphor mcp` を MCP サーバとして登録すると、エージェントは **レンダリング結果の画像と内部状態** を取得し、再ビルドの結果まで確認しながら「観測 → 編集 → 再観測 → 検証」を自律的に反復できます。

> 観測の仕組み（**Probe**）と設計の背景は metaphor 本体側にあります:
> [ai-mcp-server.md](https://github.com/shinyaoguri/metaphor/blob/main/docs/design/ai-mcp-server.md) /
> [shared-session.md](https://github.com/shinyaoguri/metaphor/blob/main/docs/design/shared-session.md)。

### 公開ツール

| ツール | 役割 |
|---|---|
| `snapshot` | 現在フレームの画像（PNG）と内部状態（`frameCount` / `time` / `probe()` 値 / 色・領域統計 / 警告）を返す |
| `input` | 実行中のスケッチへマウス・キー入力を送る（単独モードのみ） |
| `build_status` | 直近の `swift build` の成否とエラーを返す |

### セットアップ

1. スケッチを作成する。

   ```bash
   metaphor new MySketch
   cd MySketch
   ```

2. **最初に 1 度だけ、MCP サーバを登録します。** AI と協調させる＝この MCP を使う、ということなので、これが入口です。Claude Code では、スケッチのディレクトリで次を実行します。

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
   │  ・snapshot      フレーム画像 + 内部状態を返す    │
   │  ・input         マウス/キー入力を注入する        │
   │  ・build_status  再ビルドの成否とエラーを返す      │
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

この状態で AI クライアント（MCP 登録済み）から依頼すると、`metaphor mcp` は **新しくスケッチを起動せず、動作中の `watch` セッションにアタッチ**して観測します。編集は人間（VSCode）も AI（ファイルを直接編集）もディスクに書くだけで、`watch` が再ビルドして両者へ反映されます。

> **起動の順序に注意。** `metaphor mcp` が「動作中の `watch` にアタッチするか／自前で別インスタンスを起動するか」を決めるのは、**起動した瞬間に 1 度だけ**です（`.metaphor/session.json` の生存 pid を確認する）。`metaphor mcp` を起動するのは Claude Code なので、**先に `metaphor watch` を立ててから Claude Code を開いてください**。
>
> 逆順（Claude Code を先に開き `metaphor mcp` が起動済み）だと、mcp は `watch` を見つけられず **自前の別インスタンス**（ヘッドレス）を観測し、あなたのビューア窓とは別物になります。後から再チェックはしません。直すには Claude Code 側で MCP を再接続（`/mcp`）するか開き直すと、`metaphor mcp` が再起動して `watch` にアタッチし直します。

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

CLIを開発する場合:

```bash
swift build
swift test
swift run metaphor --help
```

release build を再インストール:

```bash
make install
```

### プロジェクト作成に使う metaphor を切り替える（ローカル開発版 / brew 版、direnv 推奨）

`metaphor new` でプロジェクトを作るとき、それを実行するのが **brew で入れた安定版**
（`/opt/homebrew/bin/metaphor`）なのか、**このリポジトリのローカルビルド**
（`.build/debug/metaphor`）なのかは、`PATH` 上でどちらが先に見つかるかで決まります。
毎回 `make install` / `make uninstall` で切り替えるのは面倒なので、
[direnv](https://direnv.net/) で自動化します。リポジトリには `.envrc` が同梱されており、
**このディレクトリ配下にいる間だけ** ローカルビルドを `PATH` 前方に差し込み、外に出れば
自動で brew 版に戻ります。`new` だけでなく `run` / `watch` / `doctor` など、すべての
`metaphor` コマンドがこの切り替えの対象です。

> **テンプレートの出どころも変わります。** ローカル開発版の `metaphor new` は
> リポジトリの `Templates/` を直接読みます（`make install` でコピーした
> `~/.local/share/metaphor/templates` ではありません）。テンプレートを編集して
> すぐ試せるということです。brew 版は brew が配置したテンプレートを使います。

ビルド成果物は `Syphon.framework` が隣接し `@loader_path` で解決されるため、
`make install` のような rpath 付与・再署名なしでライブビューア（`watch --viewer`）も動く。

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

- どちらが効いているか確認する: `command -v metaphor` がパスを直接示す
  （`…/metaphor-cli/.build/debug/metaphor` ＝開発版、`/opt/homebrew/bin/metaphor`
  ＝brew 版）。`metaphor --version` でも分かり、`-NN-gHASH` 付き＝開発版、
  `0.1.1` のようなクリーンなタグのみ＝brew 版。
- 既定は debug ビルド。release で確認したいときは `swift build -c release` 後に
  `METAPHOR_BUILD=release direnv allow`。
- `.build/debug` が未ビルドなら自動で brew 版にフォールバックする。
- direnv を使う場合 `make install` は不要。過去に `~/.local/bin/metaphor` を入れて
  いたら `make uninstall` で消しておくと混乱がない（direnv の方が常に優先されるため
  残っていても実害はない）。

#### 別の場所のプロジェクトをローカル開発版で作る・育てる

`~/Repos/metaphor-cli` の外（例: `~/Repos/test-meta`）を**ローカル開発版で**作って
開発したいときは、そのプロジェクトにも同じ `.envrc` を置きます。こうすると
**作成（`metaphor new .`）から日常運用（`run` / `watch`、Claude Code が読む `.mcp.json`）
まで、ずっと同じローカル開発版 `metaphor`** で一貫します。フルパス呼び出しは要りません。

```bash
mkdir ~/Repos/test-meta && cd ~/Repos/test-meta
echo 'PATH_add "$HOME/Repos/metaphor-cli/.build/debug"' > .envrc
direnv allow                  # ここで `metaphor` がローカル開発版に確定
command -v metaphor           # → …/metaphor-cli/.build/debug/metaphor を確認

metaphor new .                # その同じ metaphor で初期化（テンプレは Templates/ から読まれる）
echo '.envrc' >> .gitignore   # 生成された .gitignore に追記（マシン依存なのでコミットしない）
metaphor watch                # 以降も同じローカル開発版で動く
```

> **順序がポイント。** 先に `.envrc` ＋ `direnv allow` を済ませてから `metaphor new .`
> します。逆に `.envrc` を置く前に作成すると、`~/Repos/test-meta` には metaphor-cli の
> `.envrc` が届かないため、**作成だけ brew 版**になってしまいます（この節冒頭の
> 「`PATH` 上でどちらが先に見つかるか」の話）。
>
> `metaphor new .` は既存ディレクトリの中で初期化し、プロジェクト名はフォルダ名から
> 取ります（`.envrc`/`.git` があっても OK）。詳細は [`metaphor new`](#metaphor-new) を参照。

## Templates

テンプレートは Swift コード内の巨大な文字列ではなく、`Templates/` 配下のファイルとして管理します。

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

`templates.json` にテンプレートID、説明、生成ファイルを追加し、各 `.template`
ファイルでは次のプレースホルダを使えます。

- `{{PROJECT_NAME}}`
- `{{PROJECT_NAME_SWIFT}}`
- `{{PROJECT_NAME_JSON}}`
- `{{MODULE_NAME}}`
- `{{TEMPLATE_ID}}`
- `{{METAPHOR_DEPENDENCY}}`
- `{{METAPHOR_PACKAGE_IDENTITY_SWIFT}}`

`make install` はテンプレートを `~/.local/share/metaphor/templates` にコピーします。
別のテンプレートセットを試す場合は `METAPHOR_TEMPLATES_PATH` を指定できます。
