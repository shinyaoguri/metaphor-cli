#!/usr/bin/env python3
"""AI協調ループ往復時間の測定ハーネス (metaphor Epic #75 実測フェーズ / cli#44).

実際の AI ループ経路（`metaphor mcp` の stdio JSON-RPC）を外部から駆動し、
2 つの成功基準を数値化する:

  - 基準A: 往復時間 = 観測→編集→再観測（編集が frame.json に反映されるまで）
  - 基準B（内包）: 保存→反映時間（編集→リビルド→再起動→新フレーム）

決定論レンダリング(#70/#71)＋ provenance(#115 sourceStamp) を土台に、
「観測フレームが今の編集を反映したか」を sourceStamp の変化で機械判定する。

mcp は内部で WatchSession（ファイル監視＋ swift build ＋子プロセス再起動）を
回しつつ METAPHOR_VIEWER=1 でヘッドレス描画する。よってこのハーネスは
snapshot（観測）と編集→反映を同一経路で測れる。

使い方:
  scripts/measure-roundtrip.py <sketch-dir> [--cli PATH] [--iterations N]
       [--warm-samples M] [--out report.md]

注意: 画面キャプチャ権限は不要（ground truth は frame.png/json の読み戻し）。
"""
from __future__ import annotations
import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

GIT_ENV = {
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "safe.bareRepository",
    "GIT_CONFIG_VALUE_0": "all",
}
SENTINEL_PREFIX = "// metaphor-measure-edit:"


class MCP:
    """`metaphor mcp` を子プロセスで起動し、stdio JSON-RPC で会話する薄いクライアント。"""

    def __init__(self, cli: str, sketch: str):
        env = dict(os.environ)
        env.update(GIT_ENV)
        self.proc = subprocess.Popen(
            [cli, "mcp", sketch],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env, text=True, bufsize=1,
        )
        self._id = 0
        self._q: "queue.Queue[dict]" = queue.Queue()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._q.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def call(self, method: str, params: dict, timeout: float) -> dict | None:
        rid = self._next_id()
        self.proc.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                msg = self._q.get(timeout=max(0.05, deadline - time.monotonic()))
            except queue.Empty:
                break
            if msg.get("id") == rid:
                return msg
        return None

    def snapshot(self, timeout: float = 30.0) -> dict | None:
        """snapshot を 1 回。返り値は frame.json（dict）。失敗時 None。"""
        resp = self.call("tools/call",
                         {"name": "snapshot", "arguments": {"timeout": int(timeout)}},
                         timeout=timeout + 5)
        if not resp:
            return None
        for c in resp.get("result", {}).get("content", []):
            if c.get("type") == "text":
                try:
                    return json.loads(c["text"])
                except json.JSONDecodeError:
                    continue
        return None

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def edit_sketch(app_swift: Path, counter: int) -> None:
    """ビルド安全な sentinel 行を末尾に追記/更新してソース署名（=sourceStamp）を変える。"""
    lines = app_swift.read_text().splitlines()
    lines = [ln for ln in lines if not ln.startswith(SENTINEL_PREFIX)]
    lines.append(f"{SENTINEL_PREFIX} {counter}")
    app_swift.write_text("\n".join(lines) + "\n")


def restore_sketch(app_swift: Path, original: str) -> None:
    app_swift.write_text(original)


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def summarize(name: str, values: list[float]) -> dict:
    return {
        "metric": name,
        "n": len(values),
        "p50_ms": round(pct(values, 0.5) * 1000, 1) if values else None,
        "p95_ms": round(pct(values, 0.95) * 1000, 1) if values else None,
        "min_ms": round(min(values) * 1000, 1) if values else None,
        "max_ms": round(max(values) * 1000, 1) if values else None,
    }


def find_app_swift(sketch: Path) -> Path:
    candidates = sorted(sketch.rglob("App.swift"))
    candidates = [c for c in candidates if ".build" not in c.parts]
    if not candidates:
        # フォールバック: 最初の .swift（Package.swift 以外）
        swifts = [c for c in sorted(sketch.rglob("*.swift"))
                  if ".build" not in c.parts and c.name != "Package.swift"]
        if not swifts:
            raise SystemExit(f"編集対象の .swift が見つかりません: {sketch}")
        return swifts[0]
    return candidates[0]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sketch", help="測定対象スケッチのディレクトリ")
    ap.add_argument("--cli", default=str(Path(__file__).resolve().parents[1] / ".build/debug/metaphor"))
    ap.add_argument("--iterations", type=int, default=5, help="往復測定の反復回数")
    ap.add_argument("--warm-samples", type=int, default=10, help="warm snapshot の試行回数")
    ap.add_argument("--reflect-timeout", type=float, default=90.0, help="1 往復の上限秒")
    ap.add_argument("--out", default=None, help="Markdown レポートの出力先")
    args = ap.parse_args()

    sketch = Path(args.sketch).resolve()
    app_swift = find_app_swift(sketch)
    original = app_swift.read_text()
    print(f"[measure] sketch={sketch}")
    print(f"[measure] edit target={app_swift.relative_to(sketch)}")
    print(f"[measure] cli={args.cli}")

    # クリーン状態から開始。
    metaphor_dir = sketch / ".metaphor"
    if metaphor_dir.exists():
        shutil.rmtree(metaphor_dir)

    mcp = MCP(args.cli, str(sketch))
    warm: list[float] = []
    roundtrip: list[float] = []
    cold_ms = None
    try:
        mcp.call("initialize", {}, timeout=10)

        # cold-start: 最初の snapshot（子の Metal 初期化＋初回ビルド＋初フレームを内包）。
        t0 = time.monotonic()
        first = mcp.snapshot(timeout=60)
        cold_ms = round((time.monotonic() - t0) * 1000, 1)
        if not first:
            print("[measure] 初回 snapshot 失敗（cold-start）。中断。", file=sys.stderr)
            return 1
        baseline_stamp = first.get("sourceStamp")
        print(f"[measure] cold-start snapshot {cold_ms} ms / sourceStamp={baseline_stamp}")

        # warm snapshot: 編集なしの観測往復。
        for i in range(args.warm_samples):
            t = time.monotonic()
            r = mcp.snapshot(timeout=30)
            if r:
                warm.append(time.monotonic() - t)
            print(f"[measure] warm {i+1}/{args.warm_samples}: "
                  f"{round(warm[-1]*1000,1) if r else 'FAIL'} ms")

        # 往復: 編集 → 反映（sourceStamp 変化）まで。
        prev_stamp = baseline_stamp
        for i in range(args.iterations):
            edit_sketch(app_swift, i + 1)
            t0 = time.monotonic()
            deadline = t0 + args.reflect_timeout
            reflected = None
            while time.monotonic() < deadline:
                r = mcp.snapshot(timeout=min(20, deadline - time.monotonic()))
                if r and r.get("sourceStamp") and r.get("sourceStamp") != prev_stamp:
                    reflected = r
                    break
            if reflected:
                dt = time.monotonic() - t0
                roundtrip.append(dt)
                prev_stamp = reflected.get("sourceStamp")
                print(f"[measure] roundtrip {i+1}/{args.iterations}: "
                      f"{round(dt*1000,1)} ms / sourceStamp={prev_stamp}")
            else:
                print(f"[measure] roundtrip {i+1}/{args.iterations}: TIMEOUT "
                      f"(>{args.reflect_timeout}s)", file=sys.stderr)
    finally:
        mcp.close()
        restore_sketch(app_swift, original)
        if metaphor_dir.exists():
                shutil.rmtree(metaphor_dir)

    report = {
        "sketch": str(sketch),
        "cli": args.cli,
        "cold_start_snapshot_ms": cold_ms,
        "warm_snapshot": summarize("warm_snapshot (観測往復)", warm),
        "roundtrip": summarize("roundtrip (編集→反映=基準A/B)", roundtrip),
    }
    print("\n=== RESULT (JSON) ===")
    print(json.dumps(report, indent=2, ensure_ascii=False))

    if args.out:
        md = render_markdown(report)
        Path(args.out).write_text(md)
        print(f"[measure] レポートを書きました: {args.out}")
    return 0


def render_markdown(r: dict) -> str:
    def row(s):
        return f"| {s['metric']} | {s['n']} | {s['p50_ms']} | {s['p95_ms']} | {s['min_ms']} | {s['max_ms']} |"
    return "\n".join([
        "# AIループ往復時間 測定レポート (Epic #75 実測フェーズ)",
        "",
        f"- sketch: `{r['sketch']}`",
        f"- cli: `{r['cli']}`",
        f"- cold-start snapshot: **{r['cold_start_snapshot_ms']} ms**",
        "",
        "| 指標 | n | p50 (ms) | p95 (ms) | min (ms) | max (ms) |",
        "|---|---|---|---|---|---|",
        row(r["warm_snapshot"]),
        row(r["roundtrip"]),
        "",
        "- **warm_snapshot** = 編集なしの観測往復（request→frame ready）。基準: 観測コスト。",
        "- **roundtrip** = 編集→リビルド→再起動→新フレーム反映（sourceStamp 変化で判定）。基準A/B。",
    ]) + "\n"


if __name__ == "__main__":
    sys.exit(main())
