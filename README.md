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
- `metaphor run` で現在のスケッチを実行
- `metaphor doctor` で Swift / Xcode / テンプレート環境を確認
- `metaphor update` で CLI と `metaphor` ライブラリの更新を確認・適用

## Quick Start

インストール済みなら、これだけで始められます。

```bash
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

## Requirements

- macOS 14+
- Xcode 15+ / Swift 5.10+
- Git

## Install

### Homebrew (planned)

将来的には Homebrew tap から次のように入れられる形にします。

```bash
brew install shinyaoguri/tap/metaphor
```

この導線ではリポジトリの clone は不要で、Homebrew がビルド、配置、更新を管理します。
準備内容とリリース手順は [docs/homebrew.md](docs/homebrew.md) にまとめています。

### Direct Installer

通常の利用ではリポジトリを clone する必要はありません。最新リリースのバイナリを直接インストールします。

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
metaphor run
metaphor update
metaphor doctor
metaphor examples
metaphor version
```

### `metaphor new`

```bash
metaphor new MySketch
metaphor new MyScene --template 3d
metaphor new LiveSet --template live
metaphor new ShaderLab --template shader
```

### `metaphor update`

更新確認:

```bash
metaphor update
```

CLI本体を GitHub Releases から更新:

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
