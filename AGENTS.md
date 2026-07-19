# AGENTS.md

`metaphor-cli` は `metaphor`（Swift 製クリエイティブコーディングライブラリ）の
コマンドラインフロントエンド。スケッチの作成（`new` / `init`）・実行（`run`）・
ライブリロード（`watch`。既定で Syphon 経由のライブビューア窓を常設）・
AI エージェント向け MCP サーバ（`mcp`）・環境診断（`doctor`）・更新（`update`）を
提供する。macOS (Apple Silicon) 専用。

## ドキュメント階層

- **README.md** — 利用者向け。インストール・全コマンド・AI 協調（MCP）の正典
- **DEVELOPMENT.md** — CLI 開発者向け。プロジェクト構成・新規コマンド/MCP ツール追加・direnv 切替・テンプレート編集
- **CONTRACT.md** — metaphor ⇄ metaphor-cli のクロスリポ契約（両リポに同一内容）
- **docs/homebrew.md** — Homebrew tap / Formula のリリース手順
- **AGENTS.md（本ファイル）** — エージェント作業の起点。`CLAUDE.md` は本ファイルを import する薄いラッパー

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

### リリース手順（マージで自動）

リリースは PR の squash マージだけで自動的に走る。`release-on-merge.yml` が
bump を判定して既存の **Release** workflow を起動（tarball/Formula 生成 →
`shinyaoguri/homebrew-tap` へ Formula push）。判定の優先順位:

1. `release:skip` ラベル → リリースしない
2. `release:major` / `release:minor` / `release:patch` ラベル → 明示上書き
3. ラベル無し → **Conventional Commits の PR タイトル**（= squash コミット）から自動判定:
   `feat:` → minor / `fix:` `perf:` → patch / それ以外（docs/chore/refactor/test/ci）→ リリースなし（次の feat/fix リリースに同乗）

```bash
gh pr create --base main --title "feat(...): ..."   # → マージで自動 minor リリース
gh pr create --base main --title "docs: ..."        # → マージしてもリリースなし
gh pr create --base main --title "feat: ..." --label release:skip   # 自動リリースを抑止
```

**major は自動判定しない**（`!` 付きタイトルでも type どおりの bump）。major /
v1.0 到達は必ず `release:major` ラベルで明示する。prerelease は Release workflow の
`workflow_dispatch` で手動。連続マージ時は release.yml の concurrency が直列化し、
待機中の重複リリースは最新 1 本にまとまる。Syphon pin の自動 bump PR は
`release:patch` ラベル付きで作られ、マージで pin がユーザーへ届く。

## 気付きは Issue へ

本プロジェクトはまだ問題が残っている前提で開発している。作業中に本題以外のバグ・ドキュメント不備・改善アイデアに気付いたら、**その場で直そうとせず、気軽に `gh issue create` で Issue を立てること**（重複がないか `gh issue list --search` で軽く確認）。小さな気付きの起票も歓迎で、確信が持てないものは「提案」として立ててよい。ライブラリ側（描画・API）の事象なら `shinyaoguri/metaphor` に、両リポに跨るもの（CONTRACT.md・Probe wire format・環境変数）は両方に立てて相互リンクする。
