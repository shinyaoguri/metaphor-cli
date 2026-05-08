# Homebrew Packaging

`metaphor-cli` は `shinyaoguri/homebrew-tap` からインストールできます。
ユーザー向けの推奨導線は次のコマンドです。

```bash
brew install shinyaoguri/tap/metaphor
```

または:

```bash
brew tap shinyaoguri/tap
brew install metaphor
```

## Tap Repository

Homebrew の tap は Formula を置くための別リポジトリとして管理します。
このプロジェクトでは `shinyaoguri/homebrew-tap` を使います。

```text
homebrew-tap/
  Formula/
    metaphor.rb
```

Formula 名は `metaphor`、インストールされる実行ファイルも `metaphor` にします。
これによりユーザーは `brew install shinyaoguri/tap/metaphor` のあと、すぐ
`metaphor new` を実行できます。

## Formula Source

Formula は prebuilt binary ではなく source tarball から SwiftPM build します。
これは Homebrew の通常の作法に合わせるためです。

リリースワークフローはタグごとに次を生成します。

- `metaphor-cli_<tag>_macos_arm64.tar.gz` - curl installer / self update 用
- `metaphor-cli_macos_arm64.tar.gz` - latest installer 用
- `metaphor-cli_<tag>_source.tar.gz` - Homebrew Formula 用
- `metaphor.rb` - tap にコピーする Formula draft
- `checksums.txt` - 配布物の sha256

`Packaging/Homebrew/metaphor.rb.template` が Formula の元になります。
リリース時に `@TAG_NAME@`、`@SOURCE_SHA256@` が埋め込まれた `metaphor.rb`
が release asset として出力されます。

## Release Checklist

1. `metaphor-cli` で安定タグを切る、または Release workflow を実行する。
2. GitHub Release に `metaphor.rb` と source tarball が添付されていることを確認する。
3. `shinyaoguri/homebrew-tap` の `Formula/metaphor.rb` を release asset の `metaphor.rb` で更新する。
4. tap 側で audit と install test を走らせる。
5. tap repo に commit / push する。

```bash
brew audit --strict --online Formula/metaphor.rb
brew install --build-from-source Formula/metaphor.rb
brew test Formula/metaphor.rb
metaphor version
metaphor examples
```

## Update Behavior

Homebrew で入れた `metaphor` は Homebrew が更新管理します。
そのため Homebrew 管理下で `metaphor update self` を実行した場合、CLI は自身を
直接上書きせず、次のコマンドを案内します。

```bash
brew upgrade metaphor
```

`metaphor update library` はユーザーの Swift package 内の `metaphor` 依存を更新するため、
Homebrew インストール時でもそのまま利用できます。

## PATH Shadowing

direct installer や `make install` で入れた `~/.local/bin/metaphor` が残っていると、
Homebrew 版より先に実行されることがあります。

```bash
command -v metaphor
```

Homebrew 版を使いたい場合は、古いバイナリを削除するか `PATH` の順序を調整してください。

```bash
rm -f ~/.local/bin/metaphor
```
