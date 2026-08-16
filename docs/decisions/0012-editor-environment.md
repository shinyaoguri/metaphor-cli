# 0012: 専用エディタは作らず、VSCode の前提を同梱と `doctor` で担保する

- **状態**: 採用 (2026-08-16)

- **文脈**: `metaphor new` の生成物は AI クライアント側 (`AGENTS.md` / `CLAUDE.md` / `.mcp.json` / `PROJECT_BRIEF.md`) を整備済みだったのに、**人間側の想定環境だけがどこにも現れていなかった**。「専用エディタは作らず既存エディタに委ねる」という方針 (正典は metaphor#559) を採る以上、委ねる先の前提は生成物が示す必要がある。

  さらに、`.vscode/` を置くだけでは補完も hover も出ないことが実測で分かっていた (metaphor#578)。sourcekit-lsp の背景インデックス (既定 `auto` = Swift 6.1+ で有効) が `swift build --experimental-prepare-for-indexing` を走らせると、binaryTarget の `Syphon.framework` がコピーされず `import metaphor` が `no such module` になる。

  そして**失敗の出方が沈黙**である点が厄介だった。hover が出ないとき、原因が拡張の不在なのか、背景インデックスなのか、まだ一度もビルドしていないだけなのかを利用者が切り分けられない。

- **決定**: 生成物にエディタ設定を同梱し、切り分けは `metaphor doctor` に持たせる。

  **同梱するもの** (`Templates/common/` → `templates.json` の `commonFiles`):

  | 生成先 | 中身 |
  |---|---|
  | `.vscode/tasks.json` | `metaphor watch` (既定ビルドタスク・`isBackground`) / `metaphor run` / `swift build` |
  | `.vscode/extensions.json` | `swiftlang.swift-vscode` を推奨提示 |
  | `.vscode/settings.json` | `.build` / `.metaphor` / `Captures` / `Exports` を検索・監視から除外 |
  | `.sourcekit-lsp/config.json` | `{"backgroundIndexing": false}` (metaphor#578 の回避策) |

  **`launch.json` は同梱しない。** LLDB でスケッチを止めると Metal のフレーム駆動ごと固まり、主戦場である `watch` のホットリロードと噛み合わないため。

  **`doctor` に人間側の 3 項目を足す** (`VSCodeEnvironment.swift`、いずれも `[warn]` 止まりで CLI の動作は妨げない): Swift 拡張の有無 / `.sourcekit-lsp/config.json` の `backgroundIndexing` / ビルド成果物の有無。

  判定側の設計:

  - **検出は `~/.vscode/extensions` の走査**で、PATH 上の `code` には依存しない ("Shell Command: Install 'code' command in PATH" を実行していないマシンで偽陰性になるため)。範囲は VSCode のみ (Insiders / Cursor / VSCodium は対象外)
  - **版の比較は数値比較** (`compare(options: .numeric)`)。辞書順だと `2.10.1 < 2.9.0` になり、更新の残骸で 2 版並んでいるマシンで古い方を名乗る (テストが実際に拾った)
  - **`.sourcekit-lsp` とビルド成果物は metaphor に依存する `Package.swift` があるときだけ検査**する。`Package.swift` の有無だけを条件にすると metaphor-cli 自身のリポジトリで打っても無関係な `[warn]` が出る
  - 判定は純関数として置き、`home` / `projectRoot` を引数で受ける。実行マシンに VSCode が入っているかどうかにテスト結果が左右されない

- **影響**: 生成した瞬間から VSCode で補完と hover が効き、効かないときは `doctor` が原因を名指しする。

  同梱物はユーザーのものなので `gitignore.template` は `.vscode/` を無視しない。`.sourcekit-lsp/config.json` を消すと補完が黙って死ぬため、生成物の `AGENTS.md` に「消さない」旨を書いてある。

  `backgroundIndexing: false` は metaphor#578 が直れば不要になる回避策で、その時点でテンプレートと `doctor` の期待値を見直す必要がある — つまり**この ADR には期限がある**。

  対象を VSCode 1 本に絞ったので、他エディタ利用者には何も届かない。Xcode は別途 README の「エディタ」節で二刀流として案内している。
