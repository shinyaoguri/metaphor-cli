# 設計判断の記録 (軽量 ADR)

このリポジトリの確定した設計判断を 1 判断 1 ファイルで記録する。セッションのメモリがリセットされても、判断の背景と意図をここから復元できるようにするのが目的。

- ファイル名: `NNNN-短い説明.md` (連番)
- 構成: **状態** (採用/廃止 + 日付) / **文脈** (なぜ判断が必要だったか) / **決定** / **影響**
- 過去の判断を覆すときは古いファイルを消さず、状態を「廃止 (→ NNNN)」に変えて新しい ADR を足す
- 日付は判断がなされた日 (該当 PR のマージ日)

`metaphor` (ライブラリ側) の設計判断はあちらのリポジトリが正本。両リポに跨る契約そのものの正典は [CONTRACT.md](../../CONTRACT.md)。

## 一覧

| # | 判断 |
|---|---|
| [0001](0001-github-flow.md) | ブランチ運用は単一 main の GitHub Flow に戻す |
| [0002](0002-release-from-pr-title.md) | リリースの bump は PR タイトルから自動判定し、major は自動判定しない |
| [0003](0003-syphon-pin-automation.md) | Syphon pin の追随は dispatch + 週次ポーリングの二段構えで自動化する |
| [0004](0004-wire-schema-canon.md) | クロスリポ契約は wire schema を正典にして守る |
| [0005](0005-shared-session.md) | 共有セッション — `mcp` は `watch` にアタッチする観測クライアントにする |
| [0006](0006-fsevents-watch.md) | 変更検知は FSEvents を主、低頻度ポーリングを安全網にする |
| [0007](0007-executable-target-fallback.md) | バイナリ解決は executable target までフォールバックする |
| [0008](0008-state-dir-absolute.md) | `.metaphor/` の置き場は親が解決した絶対パスを子へ渡して一致させる |
| [0009](0009-state-preserving-reload.md) | リロードをまたぐ状態の引き継ぎは、中身を解釈せず運ぶだけにする |
| [0010](0010-releases-as-changelog.md) | 変更履歴の正本は GitHub Releases に置き、`CHANGELOG.md` は凍結する |
| [0011](0011-issue-label-taxonomy.md) | Issue ラベルは `type:` / `status:` 体系にし、起票経路によらず自動付与する |
| [0012](0012-editor-environment.md) | 専用エディタは作らず、VSCode の前提を同梱と `doctor` で担保する |
| [0013](0013-stamp-vs-rebuild-trigger.md) | 刻印 (provenance) の対象とリビルドの引き金を別集合として保つ |
