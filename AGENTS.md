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

## Branching (GitHub Flow)

- **`main`** — 唯一の長命ブランチ（デフォルト）。すべての PR は main 宛。保護: PR必須・`build-and-test` 必須・**直push禁止**・squashのみ。
- feature ブランチは main から切り、マージ後自動削除。

### リリース手順（ラベル方式）
```bash
# 通常の作業
gh pr create --base main --title "..."
# リリースするとき: PR に release ラベルを付けてマージ
gh pr create --base main --title "..." --label release:minor
gh pr merge --squash   # マージで release-on-merge.yml が release.yml を dispatch
```
`release-on-merge.yml` がラベルから bump を判定し、既存の **Release** workflow を起動
（tarball/Formula 生成 → `shinyaoguri/homebrew-tap` へ Formula push）。`release:*`
ラベル無しの PR は通常マージでリリースしない。prerelease は Release workflow の
`workflow_dispatch` で手動。Syphon pin は週次ポーリングが古ければ自動 bump PR を出す。

## 気付きは Issue へ

本プロジェクトはまだ問題が残っている前提で開発している。作業中に本題以外のバグ・ドキュメント不備・改善アイデアに気付いたら、**その場で直そうとせず、気軽に `gh issue create` で Issue を立てること**（重複がないか `gh issue list --search` で軽く確認）。小さな気付きの起票も歓迎で、確信が持てないものは「提案」として立ててよい。ライブラリ側（描画・API）の事象なら `shinyaoguri/metaphor` に、両リポに跨るもの（CONTRACT.md・Probe wire format・環境変数）は両方に立てて相互リンクする。
