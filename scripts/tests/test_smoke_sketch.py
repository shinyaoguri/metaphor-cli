#!/usr/bin/env python3
"""Unit tests for scripts/smoke-sketch.py.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests

スモーク本体は実スケッチを数分かけてビルドするので CI の毎 PR では回らない。
一方、**判定ロジックが緩む形の壊れ方**は静かで危ない — 「リロード前の古い
フレームで PASS する」「前の段の生き残りプロセスが書いたフレームで PASS する」は
どちらもスモークが緑のまま無力になる。そこで判定に関わる純ロジックをここで固定する。

とくに次の 2 つは実際に踏んだので、境界を pin してある:

- `wait_for_fresh_frame` の since 境界 — #139 (リロード後にフレームが来ない) を
  捕まえられるかどうかの分かれ目
- `collect_descendants` — SwiftPM が子を別プロセスグループで起こすため killpg が
  スケッチ本体に届かず、run の生き残りが watch の Probe を汚していた
"""

import importlib.util
import json
import sys
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

_SCRIPT = Path(__file__).resolve().parents[1] / "smoke-sketch.py"
_spec = importlib.util.spec_from_file_location("smoke_sketch", _SCRIPT)
smoke = importlib.util.module_from_spec(_spec)
sys.modules["smoke_sketch"] = smoke
_spec.loader.exec_module(smoke)


class LogTailReading(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.log = Path(self._tmp.name) / "watch.log"
        self.addCleanup(self._tmp.cleanup)

    def test_missing_file_is_not_an_error(self):
        self.assertEqual(smoke.LogTail(self.log).read(), [])

    def test_tail_returns_the_last_lines(self):
        self.log.write_text("".join("line{}\n".format(i) for i in range(10)), encoding="utf-8")
        self.assertEqual(smoke.LogTail(self.log).tail(3), ["line7", "line8", "line9"])

    def test_tail_rereads_the_file_each_time(self):
        # 判定には使わないが、診断は「子を止めた後の」中身を読む必要がある
        # (stdout がブロックバッファで、止めるまでファイルに落ちないため)。
        self.log.write_text("first\n", encoding="utf-8")
        tail = smoke.LogTail(self.log)
        self.assertEqual(tail.tail(), ["first"])
        with self.log.open("a", encoding="utf-8") as handle:
            handle.write("flushed-at-exit\n")
        self.assertEqual(tail.tail(), ["first", "flushed-at-exit"])


class BuildStatus(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.sketch = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write_status(self, mtime=None, **fields):
        path = smoke.build_status_path(self.sketch)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fields), encoding="utf-8")
        if mtime is not None:
            import os

            os.utime(path, (mtime, mtime))
        return path

    def test_missing_status_is_none(self):
        self.assertIsNone(smoke.read_build_status(self.sketch))

    def test_broken_json_is_none(self):
        # 書き込みの最中を掴んでも落ちず、次のポーリングへ回す。
        path = smoke.build_status_path(self.sketch)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"succeeded": tr', encoding="utf-8")
        self.assertIsNone(smoke.read_build_status(self.sketch))

    def test_reload_build_is_awaited(self):
        self.write_status(mtime=2000.0, succeeded=True, initial=False, exitCode=0)
        status = smoke.wait_for_build(
            self.sketch, since=1999.0, timeout=0.3, initial=False, interval=0.05
        )
        self.assertEqual(status["succeeded"], True)

    def test_initial_build_does_not_satisfy_a_reload_wait(self):
        # 起動時のビルドを「リロードした」と読むと、編集が無視されていても緑になる。
        self.write_status(mtime=2000.0, succeeded=True, initial=True, exitCode=0)
        self.assertIsNone(
            smoke.wait_for_build(
                self.sketch, since=1999.0, timeout=0.3, initial=False, interval=0.05
            )
        )

    def test_status_written_before_the_edit_is_ignored(self):
        self.write_status(mtime=1000.0, succeeded=True, initial=False, exitCode=0)
        self.assertIsNone(
            smoke.wait_for_build(
                self.sketch, since=1001.0, timeout=0.3, initial=False, interval=0.05
            )
        )

    def test_failed_build_is_returned_not_swallowed(self):
        # 失敗はタイムアウトではなく「失敗した」と返す (呼び出し側が succeeded を見る)。
        self.write_status(mtime=2000.0, succeeded=False, initial=False, exitCode=1, output="boom")
        status = smoke.wait_for_build(
            self.sketch, since=1999.0, timeout=0.3, initial=False, interval=0.05
        )
        self.assertEqual(status["succeeded"], False)

    def test_abort_stops_waiting_early(self):
        started = time.monotonic()
        self.assertIsNone(
            smoke.wait_for_build(
                self.sketch, since=0.0, timeout=30.0, interval=0.05, abort=lambda: True
            )
        )
        self.assertLess(time.monotonic() - started, 5.0)

    def test_failure_detail_keeps_the_tail_of_the_output(self):
        detail = smoke.build_failure_detail(
            {"exitCode": 1, "initial": False, "output": "a\nb\nc"}, limit=2
        )
        self.assertIn("exit 1 / initial=False", detail[0])
        self.assertEqual(detail[1:], ["b", "c"])

    def test_failure_detail_without_output(self):
        detail = smoke.build_failure_detail({"exitCode": 1, "initial": True})
        self.assertIn("(ビルド出力なし)", detail)


class ProcessTree(unittest.TestCase):
    """SwiftPM は子を別プロセスグループで起こすので killpg が孫へ届かない。

    実測では run のスケッチが生き残ったまま watch の段が走り、両者が同じ
    `.metaphor/probe/` を奪い合っていた。生き残りが書いたフレームで次の段が
    PASS しうる ＝ スモークが嘘をつくので、子孫の洗い出しは判定と同格に扱う。
    """

    def test_parses_a_ps_table(self):
        table = smoke.parse_process_table("  1     0\n 42     1\n 77    42\n")
        self.assertEqual(table, {0: [1], 1: [42], 42: [77]})

    def test_ignores_garbage_lines(self):
        table = smoke.parse_process_table("PID PPID\n42 1\nnot a row\n\n")
        self.assertEqual(table, {1: [42]})

    def test_collects_grandchildren(self):
        # metaphor(42) -> swift run(77) -> Sketch(99) の形。99 を取りこぼすと
        # スケッチ本体が生き残る。
        table = {42: [77], 77: [99]}
        self.assertEqual(smoke.collect_descendants(table, 42), [77, 99])

    def test_root_itself_is_not_included(self):
        self.assertEqual(smoke.collect_descendants({42: [42, 77]}, 42), [77])

    def test_no_children(self):
        self.assertEqual(smoke.collect_descendants({}, 42), [])

    def test_cycles_do_not_hang(self):
        # pid の再利用で循環が見えることがある。無限ループにしない。
        self.assertEqual(smoke.collect_descendants({42: [77], 77: [42, 88], 88: [77]}, 42), [77, 88])


class FreshFrame(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.sketch = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write_frame(self, mtime=None):
        path = smoke.frame_path(self.sketch)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}", encoding="utf-8")
        if mtime is not None:
            import os

            os.utime(path, (mtime, mtime))
        return path

    def test_missing_frame_is_none(self):
        self.assertIsNone(smoke.frame_mtime(self.sketch))

    def test_frame_written_after_since_is_fresh(self):
        self.write_frame(mtime=1000.0)
        self.assertEqual(
            smoke.wait_for_fresh_frame(self.sketch, since=999.0, timeout=0.3, interval=0.05),
            1000.0,
        )

    def test_frame_written_before_since_is_stale(self):
        # ここが #139 を捕まえる境界。古いフレームを認めるとリロード後に
        # フレームが来なくてもスモークが緑になる。
        self.write_frame(mtime=1000.0)
        self.assertIsNone(
            smoke.wait_for_fresh_frame(self.sketch, since=1001.0, timeout=0.3, interval=0.05)
        )

    def test_same_mtime_as_since_is_stale(self):
        self.write_frame(mtime=1000.0)
        self.assertIsNone(
            smoke.wait_for_fresh_frame(self.sketch, since=1000.0, timeout=0.3, interval=0.05)
        )

    def test_abort_stops_waiting_early(self):
        started = time.monotonic()
        self.assertIsNone(
            smoke.wait_for_fresh_frame(
                self.sketch, since=0.0, timeout=30.0, interval=0.05, abort=lambda: True
            )
        )
        self.assertLess(time.monotonic() - started, 5.0)


class SourceEditing(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.sketch = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def make(self, relative, body="import metaphor\n"):
        path = self.sketch / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        return path

    def test_picks_the_shallowest_source(self):
        self.make("Sources/Sketch/Deep/Nested/Helper.swift")
        entry = self.make("Sources/Sketch/App.swift")
        self.assertEqual(smoke.pick_source_file(self.sketch), entry)

    def test_no_sources_returns_none(self):
        self.make("Package.swift")
        self.assertIsNone(smoke.pick_source_file(self.sketch))

    def test_marker_is_appended_and_restored(self):
        path = self.make("Sources/Sketch/App.swift")
        original = smoke.append_reload_marker(path, "smoke 1")
        self.assertEqual(original, "import metaphor\n")
        self.assertEqual(path.read_text(encoding="utf-8"), "import metaphor\n// smoke 1\n")
        smoke.restore_source(path, original)
        self.assertEqual(path.read_text(encoding="utf-8"), "import metaphor\n")

    def test_marker_survives_a_file_without_trailing_newline(self):
        path = self.make("Sources/Sketch/App.swift", body="import metaphor")
        smoke.append_reload_marker(path, "smoke 2")
        self.assertEqual(path.read_text(encoding="utf-8"), "import metaphor\n// smoke 2\n")


class FailureDiagnostics(unittest.TestCase):
    def test_includes_stage_reason_elapsed_log_and_files(self):
        text = smoke.format_failure(
            "watch", "フレームが来ません", 12.34, ["[watch] 実行中"], ["frame.json (10 bytes)"]
        )
        self.assertIn("::error::[watch] フレームが来ません (12.3s 経過)", text)
        self.assertIn("[watch] 実行中", text)
        self.assertIn("frame.json (10 bytes)", text)

    def test_empty_log_and_files_are_spelled_out(self):
        # 空欄のまま出すと「ログを取り忘れたのか、本当に無かったのか」が読めない。
        text = smoke.format_failure("run", "起動しません", 1.0, [], [])
        self.assertIn("(出力なし)", text)
        self.assertIn("(ファイルなし)", text)

    def test_list_state_files_on_a_missing_directory(self):
        with TemporaryDirectory() as tmp:
            self.assertEqual(smoke.list_state_files(Path(tmp)), [])


class ArgumentDefaults(unittest.TestCase):
    def test_defaults_match_the_documented_sketch(self):
        args = smoke.parse_args([])
        self.assertEqual(args.repo, "shinyaoguri/metaphor-sketches")
        self.assertEqual(args.sketch, "2026/0718-hello")
        self.assertIsNone(args.only)
        self.assertFalse(args.headless)

    def test_only_accepts_run_and_watch(self):
        self.assertEqual(smoke.parse_args(["--only", "watch"]).only, "watch")
        with self.assertRaises(SystemExit):
            smoke.parse_args(["--only", "mcp"])


class ChildEnvironment(unittest.TestCase):
    def test_headless_sets_the_contract_env_vars(self):
        env = smoke.child_environment(headless=True, syphon_name="metaphor-smoke-run")
        self.assertEqual(env["METAPHOR_VIEWER"], "1")
        self.assertEqual(env["METAPHOR_SYPHON_NAME"], "metaphor-smoke-run")

    def test_window_mode_leaves_the_viewer_env_unset(self):
        env = smoke.child_environment(headless=False, syphon_name="metaphor-smoke-run")
        self.assertNotIn("METAPHOR_VIEWER", env)


if __name__ == "__main__":
    unittest.main()
