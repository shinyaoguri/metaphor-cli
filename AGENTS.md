# AGENTS.md

`metaphor-cli` は `metaphor`（Swift 製クリエイティブコーディングライブラリ）の
コマンドラインフロントエンド。スケッチの作成・ビルド・実行（`run` / `watch`）と、
Syphon 経由のライブビューア（`watch --viewer`）を提供する。macOS (Apple Silicon) 専用。

## Build / Test

```bash
swift build            # ビルド
swift test             # テスト
make release           # リリースビルド
make install           # ~/.local 等へインストール（Syphon.framework 同梱）
make doctor            # 環境診断
./scripts/check-contract.sh   # metaphor ⇄ metaphor-cli 契約チェック
```

## Cross-Repo Contract (metaphor ⇄ metaphor-cli)

`metaphor-cli` は `metaphor`（`shinyaoguri/metaphor`）を Swift ライブラリとしては
依存していないが、**ランタイム/バイナリの暗黙の契約**で結合している（環境変数・
stdin JSON Lines 入力・Probe ファイル・Syphon の Release pin）。完全な一覧と
変更ルールは **[CONTRACT.md](CONTRACT.md)** を参照。

**重要（エージェント向け）**: 以下に触れる変更は `metaphor-cli` 単体では完結しない。
必ず `metaphor` 側も同時に更新し、両リポジトリの `CONTRACT.md` を揃え、
`./scripts/check-contract.sh` が緑であることを確認すること。片方だけ作業中なら
もう片方に対応 PR/Issue を必ず立てる。

- 子プロセス起動時の環境変数 `METAPHOR_VIEWER` / `METAPHOR_SYPHON_NAME`（`ViewerWatch.swift` / `Watch.swift`）
- stdin へ送る入力イベントの JSON Lines キー/値（`ViewerWindow.swift`：`mouseDown` 等）
- Syphon.xcframework の Release pin（`Package.swift` の URL + checksum、`metaphor` が発行）
- Syphon 受信（`SyphonFrameSource.swift`）

CI は `scripts/check-contract.sh` で契約トークンの消失を検知する。Syphon pin は
`metaphor` の安定版 Release 時に `repository_dispatch`（`syphon-release`）を受けて
`.github/workflows/syphon-bump.yml` が自動更新 PR を作成する。

## Branching (develop 統合 + main リリーストレイン)

- **`develop`** — デフォルトブランチ／統合ライン。feature/fix/chore PR はすべて `develop` 宛。保護: PR必須・`build-and-test` 必須。
- **`main`** — **リリース専用**。変更は `develop → main` PR のみ（**直push禁止**・両ブランチ ruleset）。`develop → main` PR に `release:patch|minor|major` ラベルを付けてマージすると自動リリース。
- マージは **squash のみ**、マージ後ブランチ自動削除。

### リリース手順
```bash
# 通常の作業は develop 宛
gh pr create --base develop --title "..."
# リリースするとき
gh pr create --base main --head develop --title "Release: ..." --label release:minor
gh pr merge --squash   # マージで release-on-merge.yml が release.yml を dispatch
```
`release-on-merge.yml` がラベルから bump を判定し、既存の **Release** workflow を起動
（tarball/Formula 生成 → `shinyaoguri/homebrew-tap` へ Formula push）。ラベル無しの
`develop → main` マージはリリースしない。prerelease は Release workflow の
`workflow_dispatch` で手動。
