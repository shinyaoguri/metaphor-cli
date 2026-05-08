# metaphor-cli

Swift製の `metaphor` 開発者向けコマンドです。

このパッケージは metaphor ライブラリ本体とは分離されたCLIです。CLI自体は外部依存を持たず、生成されるスケッチプロジェクト側が `metaphor` ライブラリに依存します。

## Build

```bash
swift build
```

## Install

`metaphor` をどこからでも実行できるようにするには、release build を `~/.local/bin` にインストールします。

```bash
make install
```

インストール先を変える場合:

```bash
make install PREFIX=/usr/local
```

`~/.local/bin` が `PATH` に入っていない場合は、シェル設定に追加してください。

```bash
export PATH="$HOME/.local/bin:$PATH"
```

インストール後は、任意のディレクトリから次のように使えます。

```bash
metaphor new MySketch --template live --metaphor-path ~/Repos/metaphor
metaphor doctor
```

## Update

更新確認:

```bash
metaphor update
```

CLI本体を GitHub Releases から更新:

```bash
metaphor update self
```

現在のSwift package内で `metaphor` ライブラリ解決を更新:

```bash
metaphor update library
```

## Run

開発中にパッケージ内から直接実行する場合:

```bash
swift run metaphor --help
```

## Create a Sketch

リリース版の metaphor を参照するプロジェクト:

```bash
metaphor new MySketch --template 2d
cd MySketch
swift run
```

ローカル checkout の metaphor を参照するプロジェクト:

```bash
metaphor new MySketch --template live --metaphor-path ~/Repos/metaphor
```

## Commands

```bash
metaphor new <name>
metaphor run
metaphor update
metaphor doctor
metaphor examples
metaphor version
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

`templates.json` にテンプレートID、説明、生成ファイルを追加し、各 `.template` ファイルでは次のプレースホルダを使えます。

- `{{PROJECT_NAME}}`
- `{{PROJECT_NAME_SWIFT}}`
- `{{PROJECT_NAME_JSON}}`
- `{{MODULE_NAME}}`
- `{{TEMPLATE_ID}}`
- `{{METAPHOR_DEPENDENCY}}`
- `{{METAPHOR_PACKAGE_IDENTITY_SWIFT}}`

`make install` はテンプレートを `~/.local/share/metaphor/templates` にコピーします。別のテンプレートセットを試す場合は `METAPHOR_TEMPLATES_PATH` を指定できます。

- `2d`
- `3d`
- `shader`
- `live`
- `audio-reactive`
- `raytracing`
- `syphon`
