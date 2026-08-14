#!/usr/bin/env python3
"""Unit tests for scripts/label-issues.py.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests

この写像は人手を通らずに Issue へラベルを付けるので、間違いは黙って積もる。
特に「知らない型が黙って maintenance に寄る」形の誤りは、写像に足すべき型が
増えたことに誰も気づけなくなるという点で一番たちが悪い。そこで写像は全件を
ここで固定し、型を足すときはテストも一緒に直させる。

実際に判定に困った Issue (#127 の調査で見つかった、タイトルに型が無いもの・
コマンド名を型の位置に書いたもの) も pin してある — 写像を緩めて triage を
減らそうとしたときに、それらが誤ったラベルに落ちることで気づけるように。

写像そのものは metaphor 側と同一で、shinyaoguri/metaphor#663 が正本。
`LabelForTitle.test_every_mapped_type` が両リポで同じ表を固定しているので、
片方だけ型が増えるとここが赤くなる。
"""

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[1] / "label-issues.py"
_spec = importlib.util.spec_from_file_location("label_issues", _SCRIPT)
li = importlib.util.module_from_spec(_spec)
sys.modules["label_issues"] = li
_spec.loader.exec_module(li)

TRIAGE = "status: needs-triage"


class ParseType(unittest.TestCase):
    def test_scope_is_optional(self):
        self.assertEqual(li.parse_type("fix: 落ちる"), "fix")
        self.assertEqual(li.parse_type("fix(Core): 落ちる"), "fix")

    def test_breaking_marker_does_not_change_the_type(self):
        self.assertEqual(li.parse_type("feat(api)!: 消す"), "feat")

    def test_slashed_type(self):
        """`docs/api(Text): ...` — Issue で実際に使われている 2 領域跨ぎの書き方。"""
        self.assertEqual(li.parse_type("docs/api(Text): noFill() の扱い"), "docs/api")

    def test_not_conventional_commits(self):
        self.assertIsNone(li.parse_type("ラベルが付かない"))
        self.assertIsNone(li.parse_type(""))

    def test_type_like_prefix_is_not_a_type(self):
        """大文字や数字で始まる前置きは型ではない (`3D:` は scope であって型ではない)。"""
        self.assertIsNone(li.parse_type("3D: 箱が出ない"))
        self.assertIsNone(li.parse_type("Fix(Core): 落ちる"))

    def test_separator_requires_a_following_space(self):
        """区切りは `: ` まで求める (`ci.yml` の PR lint と同じ)。

        要約が空のタイトルはこれと `strip()` の合わせ技で落ちる: `"fix: "` は
        strip 後に `"fix:"` となり、空白を欠くので型と見なされない。
        """
        self.assertIsNone(li.parse_type("fix:"))
        self.assertIsNone(li.parse_type("fix: "))
        self.assertIsNone(li.parse_type("fix(Core):落ちる"))

    def test_summary_content_is_never_questioned(self):
        """要約の中身は問わない — 空白の数も記号も自由 (PR lint と同じ寛容さ)。"""
        self.assertEqual(li.parse_type("fix:  空白が 2 つ"), "fix")
        self.assertEqual(li.parse_type("fix: 【記号】＆ 全角"), "fix")


class LabelForTitle(unittest.TestCase):
    def test_every_mapped_type(self):
        """写像は全件をここで固定する — 型を足すならテストも直す。"""
        expected = {
            "fix": "type: bug",
            "feat": "type: feature",
            "api": "type: feature",
            "docs": "type: docs",
            "docs/api": "type: docs",
            "design": "type: design",
            "chore": "type: maintenance",
            "ci": "type: maintenance",
            "test": "type: maintenance",
            "refactor": "type: maintenance",
            "build": "type: maintenance",
            "perf": "type: maintenance",
            "dev": "type: maintenance",
        }
        self.assertEqual(li.LABEL_BY_TYPE, expected)
        for issue_type, label in expected.items():
            with self.subTest(type=issue_type):
                self.assertEqual(li.label_for_title(f"{issue_type}(Core): 要約"), label)

    def test_unknown_type_goes_to_triage(self):
        """慣例に無い型は黙って maintenance に寄せない。"""
        self.assertEqual(li.label_for_title("style(mcp): 整形"), TRIAGE)
        self.assertEqual(li.label_for_title("revert: 戻す"), TRIAGE)

    def test_command_names_are_not_types(self):
        """`new` / `templates` はコマンド名・対象であって型ではない (#127)。

        型の位置に書かれていても写像には足さない。足すと「コマンド名を型に
        してよい」を追認してしまい、`run:` `watch:` `mcp:` と際限が無くなる。
        書き手には `fix(new): ...` のように scope へ移してもらう。
        """
        for title in (
            "new: installer 残骸の ~/.local/share/metaphor/templates が brew の share を恒久的に覆い隠す",
            "templates: 生成される .gitignore に .metaphor/（Probe 出力）が入っていない",
            "CLI: ローカルMCPサーバ骨格 + snapshotツール (M1)",
        ):
            with self.subTest(title=title[:24]):
                self.assertEqual(li.label_for_title(title), TRIAGE)

    def test_freeform_titles_go_to_triage(self):
        """判定できなかった実例 (Issue #127 の調査時点) を pin する。"""
        for title in (
            "コマンド実行時に新バージョンを非侵襲に通知する update notifier",
            "AIループ往復時間の測定ハーネス（observe→edit→re-observe を計測）",
            "frame.json schemaVersion 2 (stats) — CONTRACT 整合と将来の構造化検討",
        ):
            with self.subTest(title=title[:24]):
                self.assertEqual(li.label_for_title(title), TRIAGE)

    def test_real_titles(self):
        """実際の Issue のタイトルをそのまま通す。"""
        cases = {
            "feat(watch): リロードで子の状態を運ぶ（metaphor#451 の対 PR・契約点 8）": "type: feature",
            "feat(mcp): capture_sequence ツール — 連続フレーム（時間軸）観測を露出": "type: feature",
            "ci(contract): check-contract-identity.sh の fetch_remote にリトライがなく CI が flaky に失敗する": "type: maintenance",
            "chore(ci): Syphon pin bump の bot PR が CI 未発火で滞留する（#65/#68）": "type: maintenance",
            "fix(run): 終了コードが伝播しない": "type: bug",
        }
        for title, label in cases.items():
            with self.subTest(title=title[:24]):
                self.assertEqual(li.label_for_title(title), label)

    def test_leading_whitespace_is_tolerated(self):
        self.assertEqual(li.label_for_title("  fix(Core): 落ちる"), "type: bug")


class Definitions(unittest.TestCase):
    """写像・リネーム・定義の 3 つがずれていないこと。"""

    def test_every_mapped_label_is_defined(self):
        for label in li.LABEL_BY_TYPE.values():
            with self.subTest(label=label):
                self.assertIn(label, li.LABEL_DEFINITIONS)

    def test_every_renamed_label_is_defined(self):
        for label in li.RENAMES.values():
            with self.subTest(label=label):
                self.assertIn(label, li.LABEL_DEFINITIONS)

    def test_triage_label_is_defined(self):
        self.assertIn(li.TRIAGE_LABEL, li.LABEL_DEFINITIONS)

    def test_labels_github_treats_specially_are_never_renamed(self):
        """`good first issue` / `help wanted` を改名すると外部貢献の導線が切れる。
        ワークフローが名前で読むラベルも対象外。"""
        for label in (
            "good first issue",
            "help wanted",
            "release:patch",
            "release:minor",
            "release:major",
            "release:skip",
            "dependencies",
        ):
            with self.subTest(label=label):
                self.assertNotIn(label, li.RENAMES)

    def test_colors_are_bare_hex(self):
        """`gh label create --color` は `#` を受け付けない。"""
        for name, (color, description) in li.LABEL_DEFINITIONS.items():
            with self.subTest(label=name):
                self.assertRegex(color, r"^[0-9a-f]{6}$")
                self.assertTrue(description)

    def test_dimensions_are_prefixed(self):
        """ラベルは次元の prefix を持つ (`type:` / `status:`)。"""
        for name in li.LABEL_DEFINITIONS:
            with self.subTest(label=name):
                self.assertRegex(name, r"^(type|status): ")


class SyncLabelsDryRun(unittest.TestCase):
    """`--sync-labels --dry-run` の予告が、実際に起きることと一致すること。

    ラベル体系の移行はリポジトリの外から見える操作なので、走らせる前に予告を
    読んで確かめる。予告が実際とずれていたら確認そのものが無意味になるので、
    ここで固定する。
    """

    # GitHub のデフォルト 9 枚 + このリポで足したもの（移行前の状態）。
    BEFORE = [
        "bug", "documentation", "duplicate", "enhancement", "good first issue",
        "help wanted", "invalid", "question", "wontfix",
        "release:patch", "release:minor", "release:major", "release:skip",
        "dependencies",
    ]

    def run_dry(self):
        calls = []

        def fake_gh(args, repo=None):
            calls.append(args)
            if args[:2] == ["label", "list"]:
                return json.dumps([{"name": name} for name in self.BEFORE])
            raise AssertionError(f"dry-run が書き込みを呼んだ: {args}")

        original = li._gh
        li._gh = fake_gh
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                code = li.sync_labels(repo=None, dry_run=True)
        finally:
            li._gh = original
        self.assertEqual(code, 0)
        return out.getvalue(), calls

    def test_dry_run_never_writes(self):
        _, calls = self.run_dry()
        self.assertEqual(len(calls), 1, "読み取り (label list) 以外を呼んではいけない")

    def test_renamed_names_are_not_also_created(self):
        """リネームで手に入る名前を、作成ループが重ねて予告しないこと。"""
        output, _ = self.run_dry()
        self.assertIn("rename 'bug' -> 'type: bug'", output)
        self.assertNotIn("create 'type: bug'", output)
        self.assertNotIn("create 'status: duplicate'", output)

    def test_only_the_genuinely_missing_labels_are_created(self):
        output, _ = self.run_dry()
        created = {line.split("create ")[1].strip().strip("'") for line in output.splitlines() if "create " in line}
        self.assertEqual(created, {"type: design", "type: maintenance", "status: needs-triage"})

    def test_labels_github_treats_specially_are_untouched(self):
        output, _ = self.run_dry()
        for label in ("good first issue", "help wanted", "release:patch", "no-changelog", "dependencies"):
            with self.subTest(label=label):
                self.assertNotIn(f"'{label}'", output)


class Cli(unittest.TestCase):
    def test_title_prints_the_label(self):
        """ワークフローはこの stdout をそのまま `gh issue edit --add-label` に渡す。"""
        out = io.StringIO()
        with redirect_stdout(out):
            code = li.main(["--title", "fix(Core): 落ちる"])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().strip(), "type: bug")

    def test_title_prints_triage_when_unreadable(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = li.main(["--title", "ラベルが付かない"])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().strip(), TRIAGE)

    def test_no_mode_is_an_error(self):
        with self.assertRaises(SystemExit):
            li.main([])


if __name__ == "__main__":
    unittest.main()
