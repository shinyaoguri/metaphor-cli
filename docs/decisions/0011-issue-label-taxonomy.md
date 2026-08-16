# 0011: Issue ラベルは `type:` / `status:` 体系にし、起票経路によらず自動付与する

- **状態**: 採用 (2026-08-15)

- **文脈**: Issue 15 件が無ラベルで放置されていた。原因は付け忘れではなく、**起票の入口が 2 系統あって片方だけ塞がっている**ことだった:

  | 起票経路 | ラベル | 理由 |
  |---|---|---|
  | Issue テンプレート (Web UI) | 付く | `.github/ISSUE_TEMPLATE/*.md` の `labels:` が効く |
  | `gh issue create` (AI・CLI) | **付かない** | テンプレートを経由しない |

  AGENTS.md が「気付きは気軽に `gh issue create` で起票する」と促している以上、エージェント経由の起票がむしろ主経路になる。塞がっている側が主経路という状態だった。

  さらに `metaphor` と `metaphor-cli` は CONTRACT.md で結ばれた 2 リポで、横断で Issue を読む場面がある。**ラベル体系が食い違うと横断で読めなくなる**。metaphor 側は同じ問題を先に解いていた (metaphor#663 / metaphor#665)。

- **決定**: 写像とラベル体系を**スクリプトに正本として置き**、`issues: [opened, edited]` の workflow から呼ぶ。体系は metaphor と 1 文字も違えない。

  - `scripts/label-issues.py` — 写像の正本。`--title` (1 件判定) / `--backfill` / `--sync-labels`
  - `.github/workflows/issue-labeler.yml` — **人が付けたラベルは絶対に触らない**。動くのは「1 枚も無い」か「`status: needs-triage` だけ」の 2 通り。タイトルは payload ではなく API から引くので、**triage に落ちた Issue はタイトルを直すだけで回収できる**
  - 体系: `type:` は `bug` / `feature` / `docs` / `design` / `maintenance` / `question`、`status:` は `needs-triage` / `duplicate` / `invalid` / `wontfix`。それぞれ 1 Issue に 1 枚まで
  - `good first issue` / `help wanted` (GitHub が名前で特別扱い)、`release:*` (ワークフローが名前で読む)、`dependencies` には触らない

  **cli 固有の判断**: `new:` / `templates:` / `CLI:` は写像に足さない。これらはコマンド名・対象を型の位置に書いたもので、型ではなく scope。足すと「コマンド名を型にしてよい」を追認して `run:` `watch:` `mcp:` と際限が無くなるので、triage に落として `fix(new): ...` へ直してもらう (テストで pin してある)。

- **影響**: 起票経路によらずラベルが付き、`status: needs-triage` が「機械が判定できなかった」の明示になった。タイトルを直せば判定し直されるので、triage は行き止まりではなく差し戻しとして機能する。

  無ラベルのうち型を読み取れた割合は metaphor の 97% に対しこちらは 8/15 = 53% で、タイトルの揺れが大きい。「タイトルを直せば判定し直される」経路はそのぶんよく効く。

  副産物として **`scripts/tests/` を新設**した。それまで Python テストの置き場が無く CI も走らせていなかった (`build-and-test` の 1 ジョブのみ) ため、`ci.yml` に `python3 -m unittest discover -s scripts/tests` のステップを足している。以後、`scripts/` に判定ロジックを置くときはここにテストを書く。

  ラベルの作成・リネームと既存 15 件へのバックフィルはリポジトリ設定側の操作なので、PR とは別に実行した。

  この体系は後に個人標準の着手印 (`status: in progress`) とも噛み合っている — 並行セッションの排他印として `status:` 名前空間をそのまま使える。
