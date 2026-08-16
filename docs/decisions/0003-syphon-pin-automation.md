# 0003: Syphon pin の追随は dispatch + 週次ポーリングの二段構えで自動化する

- **状態**: 採用 (2026-06-21、2026-08-10 に bot PR の作り方を改訂)

- **文脈**: `metaphor-cli` は `metaphor` を Swift ライブラリとして依存していないが、**Syphon.xcframework の binaryTarget pin** (`Package.swift` の URL + checksum) だけは共有している。この pin を発行するのは `metaphor` 側で、cli はそれに追随する側 (CONTRACT.md 契約点)。

  追随が遅れると、ライブラリ側で直った Syphon 由来の不具合が cli 経由のユーザーへ届かない。しかし checksum は公開済みアセットから引き直す機械的な値で、人が読んで判断する余地はほとんど無い。手で追う工程を残しても、判断の質は上がらず遅延だけが増える。

  最初は `repository_dispatch` (`syphon-release`) 1 本にしたが、これは **metaphor 側にクロスリポの PAT を置く必要があり、設定を忘れると黙って死ぬ**。実際そのとおりになった — metaphor 側の `CLI_DISPATCH_TOKEN` が未設定のまま v0.1.0 から v0.9.0 まで毎回 `::notice::CLI_DISPATCH_TOKEN not set` を出して `exit 0` しており、**段 1 は一度も発火していなかった** (#113 の調査)。

- **決定**: dispatch を主、**ポーリングを secret 不要の安全網**とする二段構えにする。

  - `repository_dispatch` (`syphon-release`) — metaphor のリリース時に即座に bump PR を作る (トークンが設定されていれば)
  - **週次スケジュール** — リポジトリ自身の `GITHUB_TOKEN` だけで metaphor の最新リリースを解決し、pin が古ければ PR を作る。既に最新なら何もしない (#13。当初は日次、#14 で週次へ)

  bot PR はそのままではマージできない障害が 2 つ重なっていたので、作り方も決め直した (#109):

  | 障害 | 原因 | 対処 |
  |---|---|---|
  | required check (`build-and-test`) が現れない | `GITHUB_TOKEN` 起点のイベントは再帰防止で `pull_request` workflow を発火しない (Actions の仕様) | GitHub App のインストールトークンで PR を作る |
  | `mergeStateStatus` が BLOCKED | main の ruleset の `required_signatures` に対し、bot のローカルコミットが unsigned | `sign-commits: true` (API 経由でコミットを作り GitHub が署名する) |

  中身が機械的な値だけであることを踏まえ、この PR は **auto-merge** にする。誤った pin は `binaryTarget` を実際に解決する `build-and-test` が落とす (#113)。

- **影響**: metaphor の安定版が出てから cli のユーザーへ届くまでの経路が、人の操作を挟まずに繋がった。実測では改善前、v0.8.0 (08-01) が pin に反映されたのは 08-10 で **9 日**かかっており、しかもその PR は作られたまま放置されていた。

  「PR を close → reopen して CI を発火させる」という以前の回避策は**使ってはいけない**。署名が付かないので `required_signatures` を満たせず、CI を緑にしてもマージできない (DEVELOPMENT.md に明記済み)。

  bot PR のタイトルは `chore:` なので、[ADR 0002](0002-release-from-pr-title.md) の自動判定ではリリースが走らない。そのため `syphon-bump.yml` が `release:patch` ラベルを貼って段 2→3 を繋ぐ。このラベル結合は `scripts/check-contract.sh` が機械検査する。

  既知の限界: 週次ポーリングなので dispatch が死んでいると最大 1 週間遅れる。届き切ったかどうかの最終判定は `release-pipeline-audit.yml` が tap の Formula から逆算して行う。
