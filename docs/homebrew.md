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

## Release Flow

stable リリース時は Release workflow が `shinyaoguri/homebrew-tap` の
`Formula/metaphor.rb` を自動で更新します。prerelease (`vX.Y.Z-LABEL.N`) の
ときは tap への反映はスキップされ、GitHub Release に Formula draft が
添付されるだけになります。

1. `metaphor-cli` で Release workflow を `bump=patch/minor/major` で実行する。
2. workflow が以下を行う:
   - source tarball / バイナリ / `metaphor.rb` を GitHub Release に添付。
   - stable のときだけ `shinyaoguri/homebrew-tap` を checkout して
     `Formula/metaphor.rb` を上書き、`Update metaphor to <tag>` という
     commit を push。
3. 反映後に tap 側で audit と install test を回す（任意）。

```bash
brew update
brew audit --strict --online shinyaoguri/tap/metaphor
brew install --build-from-source shinyaoguri/tap/metaphor
brew test shinyaoguri/tap/metaphor
metaphor version
metaphor examples
```

## PAT Setup

tap repo への push は `GITHUB_TOKEN` では行えないため、PAT を
metaphor-cli リポジトリの secret として登録します。

1. GitHub の Settings → Developer settings → Personal access tokens →
   **Fine-grained tokens** で新規発行する。
   - Resource owner: `shinyaoguri`
   - Repository access: `Only select repositories` →
     `shinyaoguri/homebrew-tap` のみ
   - Repository permissions:
     - **Contents**: Read and write
     - **Metadata**: Read-only (自動付与)
   - Expiration: 任意（社内ポリシーがあればそれに合わせる）
2. 発行された token をコピーする。
3. `metaphor-cli` repo の Settings → Secrets and variables → Actions →
   New repository secret で登録する。
   - Name: `HOMEBREW_TAP_TOKEN`
   - Secret: 上記の token
4. workflow の `Checkout homebrew-tap` step が `secrets.HOMEBREW_TAP_TOKEN`
   を参照しているので、これで自動 push が動くようになる。

token を rotate するときは同じ secret 名で値だけ差し替えれば OK。

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
