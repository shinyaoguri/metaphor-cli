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

## Tap Credentials (GitHub App)

Actions が自動発行する `GITHUB_TOKEN` は `metaphor-cli` にしかスコープされず、
別リポジトリである tap には push できません。そのため tap への push だけは
専用の資格情報を使います。

採用しているのは **GitHub App のインストールトークン**です。App の private key
自体は無期限ですが、そこから発行されるトークンは 1 時間で失効するため、
定期的な rotate が要らず、万一漏れても権限が残り続けません。PAT
(fine-grained) は最長 1 年で切れるたびにリリースが止まり、Deploy key は
無期限の push 権限が漏洩時にそのまま残るため、いずれも採用していません。

### 初回セットアップ（一度だけ）

この App は tap への push 専用ではなく、**このリポジトリの自動化全般**に使います
（もう 1 つの用途は `syphon-bump.yml` が開く Syphon pin bump PR。GITHUB_TOKEN で
PR を作ると CI が発火せず署名も付かないため、同じ App のトークンで作っています。
詳細は [DEVELOPMENT.md](../DEVELOPMENT.md) の Syphon pin bump の節）。secret 名が
`REPO_AUTOMATION_APP_*` と中立なのはそのためです。

1. GitHub の Settings → Developer settings → **GitHub Apps** → New GitHub App
   - GitHub App name: 任意（例 `metaphor-repo-automation`）
   - Homepage URL: 任意（リポジトリ URL でよい）
   - **Webhook: Active のチェックを外す**（不要）
   - Repository permissions:
     - **Contents: Read and write** — tap への push と bump PR のブランチ作成
     - **Pull requests: Read and write** — bump PR の作成
     - （Metadata: Read-only は自動付与）
   - Where can this GitHub App be installed?: Only on this account
2. 作成後の General 画面で **Client ID**（`Iv23li...` 形式）を控える。
   すぐ上にある App ID とは別の値なので取り違えないこと。
3. 同じ画面下部の Private keys → **Generate a private key** で `.pem` を
   ダウンロードする（再ダウンロード不可。紛失したら再生成する）。
4. 左メニュー Install App → 自分のアカウントに install。
   Repository access は **Only select repositories** →
   `shinyaoguri/homebrew-tap` と `shinyaoguri/metaphor-cli` の **2 つ**を選ぶ。
   （tap だけだと bump PR の作成が `Mint app token` step で失敗します）
5. `metaphor-cli` repo の Settings → Secrets and variables → Actions →
   New repository secret で 2 つ登録する。
   - `REPO_AUTOMATION_APP_CLIENT_ID` — 手順 2 の Client ID
   - `REPO_AUTOMATION_APP_PRIVATE_KEY` — 手順 3 の `.pem` の**中身全体**
     （`-----BEGIN...` から `-----END...` まで、改行を含めてそのまま貼る）

   Client ID 自体は秘密ではありませんが、private key と対で扱うほうが
   参照箇所が 1 つにまとまるため secret に置いています。

Release workflow の `Mint homebrew-tap token` step
(`actions/create-github-app-token`) がこの 2 つからトークンを発行し、
続く `Checkout homebrew-tap` に渡します。トークンは step ごとに
`repositories:` で必要なリポジトリだけに絞っています。

### 運用

期限切れによる rotate は不要です。private key を差し替えたいときは、App の
画面で新しい key を生成して `REPO_AUTOMATION_APP_PRIVATE_KEY` を上書きし、
古い key を App 側から削除します。

`Bad credentials` や 403 で落ちるときは、App の install の Repository access に
対象リポジトリが含まれているかを確認してください（tap への push なら
`homebrew-tap`、Syphon pin bump PR の作成なら `metaphor-cli`）。
**この install 範囲を絞ると tap だけでなく bump PR も止まります。**

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
