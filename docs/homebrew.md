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

stable リリース時は Release workflow が `shinyaoguri/homebrew-tap` へ
`Formula/metaphor.rb` の更新 **PR** を出します。prerelease (`vX.Y.Z-LABEL.N`) の
ときは tap への反映はスキップされ、GitHub Release に Formula draft が
添付されるだけになります。

1. `metaphor-cli` のリリースが出る（週次の pin bump からの自動、または手動 dispatch）。
2. Release workflow が以下を行う:
   - source tarball / バイナリ / `metaphor.rb` を GitHub Release に添付。
   - stable のときだけ tap に `metaphor-<version>` ブランチを push し、
     `metaphor <version>` というタイトルの PR を作る。
3. tap の `brew test-bot` が PR で走る。ここで **実際に Formula をビルドし
   `brew test` を通し、macOS 版ごとの bottle を作ります**。
4. green になると tap の `publish.yml` が `brew pr-pull` で bottle を取り込み、
   main へ push して PR を閉じる。

**人の承認は挟みません。** 3 が実質のレビューで、壊れた Formula はそこで止まります。

### なぜ直 push をやめたか

以前は tap の main へ直接 commit していました。tap の `brew test-bot` は
`--only-formulae`（実ビルド + `brew test`）を `pull_request` でしか走らせないため、
直 push で通っていたのは構文チェックだけで、**壊れた Formula がそのまま
ユーザーに届く経路**になっていました。PR を経由すると同時に bottle も手に入るので、
`brew install` が毎回 Swift のソースビルドを回す必要もなくなります。

### bottle の置き場

bottle は **tap 自身の GitHub Release**（`metaphor-<version>` タグ）に置かれます。
`brew pr-pull` の既定で、手作業の設定は要りません。

> **触ってはいけない**: `HOMEBREW_GITHUB_PACKAGES_*` や `--root-url` を渡して
> GitHub Packages (ghcr.io) に振り替えようとすると、**アップロード先だけ**が
> ghcr へ逸れ、Formula に書かれる `root_url` は GitHub Release のまま残ります。
> しかも作られるパッケージは private です。2026-08-10 にこれで `metaphor 0.7.2`
> の Formula が実体の無い bottle を指し、`brew install` が 404 で落ちました
> （homebrew-tap #3 / #4）。**アップロード先と `root_url` は必ず同じ既定から
> 出させること。**

bottle を取り込めなかった場合は **bottle 無しで Formula だけ merge され**
（配布は止まらない）、run が赤くなって気付けるようにしてあります。

### 手元での確認（任意）

```bash
brew update
brew audit --strict --online shinyaoguri/tap/metaphor
brew install --build-from-source shinyaoguri/tap/metaphor
brew test shinyaoguri/tap/metaphor
metaphor version
metaphor examples
```

## 届いたかどうかの監査

metaphor(ライブラリ) の安定版が brew のユーザーに届くまでには 4 段あり、
どこかが止まっても前後の段は緑のままに見えます。実際、metaphor から
metaphor-cli への `repository_dispatch` は資格情報が未設定のまま一度も発火せず、
リリースは毎回成功扱いでした（`v0.8.0` の pin 反映まで 9 日）。

`release-pipeline-audit.yml` が毎日 tap の Formula から逆算し、48 時間経っても
届いていなければ詰まっている段を名指しして Issue を立てます。全段揃うと自動で
クローズされます。手元でも同じ判定を出せます:

```bash
python3 scripts/audit-release-pipeline.py --dry-run
```

| 段 | 何が起きる | どこ |
|---|---|---|
| 1 | metaphor の安定版が `repository_dispatch`(`syphon-release`) を撃つ | metaphor `release.yml` |
| 2 | Syphon pin を上げる PR が出て、CI green で auto-merge | `syphon-bump.yml` |
| 3 | `release:patch` ラベルで metaphor-cli のリリースが出る | `release-on-merge.yml` → `release.yml` |
| 4 | tap へ Formula PR → bottle 込みで main へ | `release.yml` → homebrew-tap `publish.yml` |

## Tap Credentials (GitHub App)

Actions が自動発行する `GITHUB_TOKEN` は発行元のリポジトリにしかスコープされず、
リポジトリをまたぐ操作には使えません。そのため次の 3 つは専用の資格情報を使います。

| 使う場所 | 何をする | 必要な install 先 |
|---|---|---|
| metaphor-cli `release.yml` | tap へ Formula 更新 PR を出す | `homebrew-tap` |
| metaphor-cli `syphon-bump.yml` | Syphon pin bump PR を出す | `metaphor-cli` |
| **metaphor `release.yml`** | metaphor-cli へ `repository_dispatch` を撃つ | `metaphor-cli` |

採用しているのは **GitHub App のインストールトークン**です。App の private key
自体は無期限ですが、そこから発行されるトークンは 1 時間で失効するため、
定期的な rotate が要らず、万一漏れても権限が残り続けません。PAT
(fine-grained) は最長 1 年で切れるたびにリリースが止まり、Deploy key は
無期限の push 権限が漏洩時にそのまま残るため、いずれも採用していません。

### 初回セットアップ（一度だけ）

現在使っているのは **`metaphor-tap-publisher`** です。名前は tap 専用に見えますが、
実際は上の表の 3 用途すべてに使います（`syphon-bump.yml` の PR を GITHUB_TOKEN で
作ると CI が発火せず署名も付かないため、同じ App のトークンで作っています。詳細は
[DEVELOPMENT.md](../DEVELOPMENT.md) の Syphon pin bump の節）。App 名は歴史的経緯で
そのままですが、secret 名を `REPO_AUTOMATION_APP_*` と中立にしてあるのは用途が
広がっているためです。**新しい App を作る必要はありません** — 以下は作り直すときの
手順です。

1. GitHub の Settings → Developer settings → **GitHub Apps** → New GitHub App
   - GitHub App name: 任意（既存は `metaphor-tap-publisher`）
   - Homepage URL: 任意（リポジトリ URL でよい）
   - **Webhook: Active のチェックを外す**（不要）
   - Repository permissions:
     - **Contents: Read and write** — ブランチの作成・push と `repository_dispatch`
       （dispatches エンドポイントが見るのはこの権限）
     - **Pull requests: Read and write** — tap の Formula PR と Syphon pin bump PR
     - （Metadata: Read-only は自動付与）
   - Where can this GitHub App be installed?: Only on this account
2. 作成後の General 画面で **Client ID**（`Iv23li...` 形式）を控える。
   すぐ上にある App ID とは別の値なので取り違えないこと。
3. 同じ画面下部の Private keys → **Generate a private key** で `.pem` を
   ダウンロードする（再ダウンロード不可。紛失したら再生成する）。
4. 左メニュー Install App → 自分のアカウントに install。
   Repository access は **Only select repositories** →
   `shinyaoguri/homebrew-tap` と `shinyaoguri/metaphor-cli` の **2 つ**を選ぶ。
   （tap だけだと bump PR の作成が `Mint app token` step で失敗します。
   metaphor 側から dispatch を撃つのに必要なのは `metaphor-cli` への install で、
   `metaphor` 自体を install 先に加える必要はありません）
5. `metaphor-cli` **と `metaphor`** の両方の repo で Settings → Secrets and
   variables → Actions → New repository secret に 2 つ登録する。
   - `REPO_AUTOMATION_APP_CLIENT_ID` — 手順 2 の Client ID
   - `REPO_AUTOMATION_APP_PRIVATE_KEY` — 手順 3 の `.pem` の**中身全体**
     （`-----BEGIN...` から `-----END...` まで、改行を含めてそのまま貼る）

   Client ID 自体は秘密ではありませんが、private key と対で扱うほうが
   参照箇所が 1 つにまとまるため secret に置いています。
   **`metaphor` 側に登録し忘れると、リリースは出るが下流に伝わらず
   `Mint metaphor-cli dispatch token` step で赤くなります。**

Release workflow の `Mint homebrew-tap token` step
(`actions/create-github-app-token`) がこの 2 つからトークンを発行し、
続く `Checkout homebrew-tap` に渡します。トークンは step ごとに
`repositories:` で必要なリポジトリだけに絞っています。

### 運用

期限切れによる rotate は不要です。private key を差し替えたいときは、App の
画面で新しい key を生成して `REPO_AUTOMATION_APP_PRIVATE_KEY` を上書きし、
古い key を App 側から削除します。

`Bad credentials` や 403 で落ちるときは、App の install の Repository access に
対象リポジトリが含まれているかを確認してください（tap の Formula PR なら
`homebrew-tap`、Syphon pin bump PR と metaphor からの dispatch なら `metaphor-cli`）。
**この install 範囲を絞ると、上の表の 3 用途がまとめて止まります。**

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
