#!/usr/bin/env python3
"""実スケッチを `metaphor run` / `metaphor watch` で動かすスモーク (Issue #153)。

CI には「テンプレートを生成して build が通る」までの検査 (`check-templates.sh`)
と契約チェックしかなく、**育った実物のスケッチを動かして初めて出る穴**を拾えて
いなかった。実際 #139 (watch のリロード後にフレームが復帰しない) も #133
(`.metaphor/` の置き場) も、人が作品を動かしていて偶然気づいたもので、雛形の
ビルド検査では出ない。ここが埋めるのは **CLI 固有の経路** — run / watch /
ホットリロードが端から端まで生きていること。

## 何を PASS の根拠にするか

`.metaphor/probe/current/frame.json` は放っておいても出ない。`request.json` への
**応答としてのみ**書かれる (CONTRACT.md 契約点 4)。そこでスモークは自分で
request.json を書かず、`--metrics` を付けて **CLI 自身にリクエストを出させる**。

    metaphor run --metrics  ->  CLI が request.json を書く (MetricsPoller)
                            ->  子スケッチが frame.json を書く
                            ->  CLI が performance を読んで [metrics] 行を出す

つまり `frame.json` の mtime が進んだことをもって
**CLI -> 子 -> Probe -> CLI の往復が生きている**と判定できる。ログの
`[metrics]` 行ではなく mtime を見るのは、非 TTY のステータスラインが
「内容が変わったときだけ 1 行」を出す仕様 (MetricsReporter.swift) で、
値が偶然同じだと行が出ないため。

watch のスモークはさらに一歩進めて、**リロード後に新しいフレームが来るか**まで
見る。#139 はまさにここが症状だった (リロードしたのにフレームが更新されない)。

## 判定にログを使わない理由 (実測で分かったこと)

最初の版は `[watch] 実行中` / `[watch] リロードしました` のログ行を待っていたが、
**リダイレクト時の CLI の stdout はブロックバッファされる**ので、これらの行は
プロセスが終わるまでファイルに現れない (実測: 15 分走らせて、全部の watch 行が
SIGINT の後にまとめて flush された)。`[metrics]` 行だけ先に見えるのは、
ステータスラインが stderr へ出ているため。

そこで制御フローは**ファイルだけ**で組む:

- 子が生きているか -> `.metaphor/probe/current/frame.json` の mtime
- リロードが起きたか -> `.metaphor/build-status.json` (`initial: false` で書き直される。
  `succeeded` / `output` も入っているので、ビルド失敗を待たずに判定できる)

ログは診断用にだけ取っておく (失敗時は子を止めてから読む = バッファを flush させる)。

## 使い方

    python3 scripts/smoke-sketch.py                    # run + watch
    python3 scripts/smoke-sketch.py --only watch       # watch だけ
    python3 scripts/smoke-sketch.py --sketch-dir ~/work/my-sketch --keep

`--headless` は子へ `METAPHOR_VIEWER=1` (契約点 5) を渡し、窓を開かずに動かす
(フレームは Probe に書かれる。ビューア窓への frame IPC は `watch --viewer` 経路だけ)。
窓を開けない環境 (GUI セッションの無い CI) 向けの逃げ道で、ホットリロードの検査
そのものは窓モードと同じだけ効く。
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_DEFAULT = "shinyaoguri/metaphor-sketches"
SKETCH_DEFAULT = "2026/0718-hello"

# 依存が metaphor 1 本だけでビルドが軽い作品を既定にしている。重い作品を選ぶと
# スモークの所要時間がビルド待ちで埋まり、flaky の切り分けが効かなくなる。

# --- ログの読み取り（診断専用。判定には使わない） -----------------------------


class LogTail:
    """子プロセスのログファイルを読む。**失敗時の診断のためだけ**に使う。

    stdout がブロックバッファされる以上、ここから「今どうなっているか」は
    読めない (モジュール冒頭の注記)。読むのは子を止めた後で、そのとき初めて
    バッファの中身がファイルへ落ちる。パイプではなくファイルに束ねているのは、
    そのまま CI の artifact として持ち出せるため。
    """

    def __init__(self, path):
        self.path = Path(path)

    def read(self):
        if not self.path.exists():
            return []
        with self.path.open("r", encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()

    def tail(self, count=40):
        return self.read()[-count:]


# --- 出来事の判定（純ロジック。単体テストの対象） ------------------------------


def frame_path(sketch_dir):
    """CONTRACT.md 契約点 4 の単一フレーム出力。"""
    return Path(sketch_dir) / ".metaphor" / "probe" / "current" / "frame.json"


def frame_mtime(sketch_dir):
    """frame.json の mtime。未生成なら None。"""
    path = frame_path(sketch_dir)
    try:
        return path.stat().st_mtime
    except FileNotFoundError:
        return None


def wait_for_fresh_frame(sketch_dir, since, timeout, interval=0.5, abort=None):
    """`since` より新しい frame.json が書かれるまで待ち、その mtime を返す。

    `abort()` が真を返したら即座に諦める (子が死んだのに待ち続けないため)。
    見つからなければ None。
    """
    deadline = time.monotonic() + timeout
    while True:
        mtime = frame_mtime(sketch_dir)
        if mtime is not None and mtime > since:
            return mtime
        if abort is not None and abort():
            return None
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval)


def build_status_path(sketch_dir):
    """`metaphor watch` がビルドのたびに書く共有セッションの結果 (SharedSession.swift)。"""
    return Path(sketch_dir) / ".metaphor" / "build-status.json"


def read_build_status(sketch_dir):
    """build-status.json を (mtime, 中身) で返す。無い・壊れているなら None。

    アトミック書き込みだが、読み側が壊れた JSON を掴んだときに落ちる意味は
    無いので None に倒して次のポーリングへ回す。
    """
    path = build_status_path(sketch_dir)
    try:
        mtime = path.stat().st_mtime
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    return mtime, payload


def wait_for_build(sketch_dir, since, timeout, initial=None, interval=0.5, abort=None):
    """`since` より後に書かれた build-status.json を待ち、その中身を返す。

    `initial` を指定すると `initial` フィールドが一致するものだけを認める
    (True = 起動時のビルド / False = 編集によるリロード)。成否は見ないので、
    呼び出し側が `succeeded` を確かめる — ビルド失敗はタイムアウトではなく
    「失敗した」と報告したい。
    """
    deadline = time.monotonic() + timeout
    while True:
        found = read_build_status(sketch_dir)
        if found is not None:
            mtime, payload = found
            if mtime > since and (initial is None or payload.get("initial") is initial):
                return payload
        if abort is not None and abort():
            return None
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval)


def build_failure_detail(status, limit=20):
    """ビルド失敗の診断行。`output` は末尾だけ拾う (フルビルドのログは長い)。"""
    detail = ["exit {} / initial={}".format(status.get("exitCode"), status.get("initial"))]
    output = (status.get("output") or "").splitlines()
    detail.extend(output[-limit:] if output else ["(ビルド出力なし)"])
    return detail


# --- スケッチのソースを 1 箇所つつく（純ロジック。単体テストの対象） ----------


def pick_source_file(sketch_dir):
    """リロードの引き金にする .swift を 1 本選ぶ。

    `Sources/` 配下で一番短いパスを選ぶ (App.swift のような入口が来やすく、
    生成物や補助ファイルを引きにくい)。見つからなければ None。
    """
    candidates = sorted(
        (p for p in Path(sketch_dir).glob("Sources/**/*.swift") if p.is_file()),
        key=lambda p: (len(p.parts), str(p)),
    )
    return candidates[0] if candidates else None


def append_reload_marker(source_file, marker):
    """末尾へコメント 1 行を足す。戻り値は復元用の元テキスト。

    振る舞いを変えない変更にしておく — スモークが見たいのは「ソースが変わったら
    リロードされ、新しいフレームが来るか」であって、描画内容ではない。
    """
    original = source_file.read_text(encoding="utf-8")
    body = original if original.endswith("\n") else original + "\n"
    source_file.write_text(body + "// {}\n".format(marker), encoding="utf-8")
    return original


def restore_source(source_file, original):
    source_file.write_text(original, encoding="utf-8")


# --- 診断（純ロジック。単体テストの対象） --------------------------------------


def format_failure(stage, reason, elapsed, log_lines, state_files):
    """失敗をひとかたまりの診断テキストにする。

    CI のログしか手元に残らない前提なので、「どこで・何秒待って・そのとき
    ログと .metaphor に何があったか」を 1 箇所にまとめる。
    """
    out = [
        "::error::[{}] {} ({:.1f}s 経過)".format(stage, reason, elapsed),
        "--- 子プロセスのログ (末尾) ---",
    ]
    out.extend(log_lines or ["(出力なし)"])
    out.append("--- .metaphor 配下 ---")
    out.extend(state_files or ["(ファイルなし)"])
    return "\n".join(out)


def list_state_files(sketch_dir):
    root = Path(sketch_dir) / ".metaphor"
    if not root.exists():
        return []
    found = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            try:
                size = path.stat().st_size
            except OSError:
                size = -1
            found.append("{} ({} bytes)".format(path.relative_to(sketch_dir), size))
    return found


# --- 子プロセスの起動と停止 ----------------------------------------------------


def parse_process_table(text):
    """`ps -eo pid=,ppid=` の出力を {ppid: [pid, ...]} に畳む（純ロジック）。"""
    children = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
    return children


def collect_descendants(children, root):
    """`root` から辿れる子孫 pid を返す（root 自身は含まない。純ロジック）。

    自己参照や循環（pid の再利用で起こりうる）で無限ループしないよう、
    見た pid は二度辿らない。
    """
    seen = set()
    queue = list(children.get(root, []))
    while queue:
        pid = queue.pop()
        if pid in seen or pid == root:
            continue
        seen.add(pid)
        queue.extend(children.get(pid, []))
    return sorted(seen)


def live_descendants(root_pid):
    result = subprocess.run(
        ["ps", "-eo", "pid=,ppid="], capture_output=True, text=True, check=False
    )
    return collect_descendants(parse_process_table(result.stdout), root_pid)


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


class Child:
    """CLI を起動し、**孫まで含めて**確実に落とす。

    `metaphor run` は `swift run` を、`swift run` はスケッチ本体を起動する。
    ところが SwiftPM は子を新しいプロセスグループで起こすので、こちらが
    `killpg` を撃っても**スケッチ本体には届かない**。実際、最初の版では run の
    スケッチが生き残ったまま watch のスモークが走り、両者が同じ
    `.metaphor/probe/` を奪い合って `frame.json.tmp -> frame.json` の rename が
    数百回失敗していた。放置すると「前の段の生き残りが書いたフレーム」で
    次の段が PASS する ＝ **スモークが嘘をつく**。

    そこで止める前に子孫 pid を数えておき、グループへ SIGINT を撃ったあと
    生き残りを SIGTERM -> SIGKILL で個別に片付ける。
    """

    def __init__(self, argv, cwd, log_path, env):
        self.argv = argv
        self.log_path = Path(log_path)
        self._handle = self.log_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            argv,
            cwd=str(cwd),
            stdout=self._handle,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

    def is_dead(self):
        return self.process.poll() is not None

    def stop(self, grace=10.0):
        # 親を落とすと子孫が孤児になって辿れなくなるので、先に数えておく。
        descendants = live_descendants(self.process.pid)
        if self.process.poll() is None:
            try:
                os.killpg(os.getpgid(self.process.pid), signal.SIGINT)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                self.process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    self.process.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    pass

        for sig in (signal.SIGTERM, signal.SIGKILL):
            survivors = [pid for pid in descendants if _alive(pid)]
            if not survivors:
                break
            for pid in survivors:
                try:
                    os.kill(pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
            deadline = time.monotonic() + grace
            while any(_alive(pid) for pid in survivors) and time.monotonic() < deadline:
                time.sleep(0.2)

        if not self._handle.closed:
            self._handle.close()
        return [pid for pid in descendants if _alive(pid)]


def child_environment(headless):
    env = os.environ.copy()
    if headless:
        # 契約点 2: METAPHOR_VIEWER=1 で窓を開かない (出力は Probe。--metrics が
        # METAPHOR_PROBE=1 を足す)。
        env["METAPHOR_VIEWER"] = "1"
    return env


# --- スモーク本体 --------------------------------------------------------------


def resolve_binary(explicit, repo_root):
    if explicit:
        return str(Path(explicit).expanduser().resolve())
    built = repo_root / ".build" / "debug" / "metaphor"
    if built.exists():
        return str(built)
    found = shutil.which("metaphor")
    if found:
        return found
    raise SystemExit(
        "metaphor バイナリが見つかりません。`swift build` するか --metaphor-bin を指定してください。"
    )


def checkout_sketch(repo, ref, sketch, dest):
    """作品 1 本だけを sparse + shallow で取り出す。

    作品リポジトリは年々増える一方なので、全部持ってくると CI の取得時間が
    作品数に比例してしまう。見たいのは 1 本だけ。
    """
    url = "https://github.com/{}.git".format(repo)
    subprocess.run(
        ["git", "clone", "--filter=blob:none", "--sparse", "--depth", "1",
         "--branch", ref, url, str(dest)],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(dest), "sparse-checkout", "set", sketch],
        check=True,
    )
    sketch_dir = Path(dest) / sketch
    if not (sketch_dir / "Package.swift").exists():
        raise SystemExit(
            "スケッチが取り出せませんでした: {}/{} ({} に Package.swift がありません)".format(
                repo, sketch, sketch_dir
            )
        )
    return sketch_dir


class Stage:
    """1 つのスモーク段。失敗の報告と後片付けをここに集める。"""

    def __init__(self, name, binary, sketch_dir, args, log_dir, argv):
        self.name = name
        self.sketch_dir = sketch_dir
        self.args = args
        self.started = time.monotonic()
        self.log_path = Path(log_dir) / "{}.log".format(name)
        self.tail = LogTail(self.log_path)
        self.child = Child(
            [binary] + argv,
            cwd=sketch_dir,
            log_path=self.log_path,
            env=child_environment(args.headless),
        )

    @property
    def elapsed(self):
        return time.monotonic() - self.started

    def fail(self, reason, extra=None):
        # 先に子を止める。stdout はリダイレクト時ブロックバッファなので、
        # 止めるまでログがファイルに落ちない（モジュール冒頭の注記）。
        leftovers = self.child.stop()
        lines = list(extra or [])
        if lines:
            lines.append("--- 以下は子プロセスのログ ---")
        lines.extend(self.tail.tail())
        if leftovers:
            lines.append("(停止できなかった子孫プロセス: {})".format(leftovers))
        print(
            format_failure(
                self.name, reason, self.elapsed, lines, list_state_files(self.sketch_dir)
            ),
            file=sys.stderr,
        )
        return False

    def ok(self, what):
        print("[{}] OK — {} ({:.1f}s)".format(self.name, what, self.elapsed))
        return True

    def stop(self):
        leftovers = self.child.stop()
        if leftovers:
            print(
                "::warning::[{}] 停止できなかった子孫プロセスがあります: {}".format(
                    self.name, leftovers
                ),
                file=sys.stderr,
            )


def smoke_run(binary, sketch_dir, args, log_dir):
    """`metaphor run --metrics` で最初のフレームが来るところまで。"""
    since = time.time()
    stage = Stage(
        "run", binary, sketch_dir, args, log_dir,
        ["run", "--metrics", "--metrics-interval", "0.5"],
    )
    try:
        mtime = wait_for_fresh_frame(
            sketch_dir,
            since=since,
            timeout=args.build_timeout + args.frame_timeout,
            abort=stage.child.is_dead,
        )
        if mtime is None:
            if stage.child.is_dead():
                return stage.fail(
                    "スケッチが終了しました (exit {})".format(stage.child.process.poll())
                )
            return stage.fail(
                "frame.json が出ませんでした (CLI -> 子 -> Probe -> CLI の往復が切れています)"
            )
        return stage.ok("初回フレーム到達")
    finally:
        stage.stop()


def smoke_watch(binary, sketch_dir, args, log_dir):
    """`metaphor watch --no-viewer --metrics` でホットリロードまで。

    #139 クラスの回帰を捕まえるのがここ。「リロードした」だけでは足りず、
    **リロード後に新しいフレームが来る**ところまで見る。
    """
    since = time.time()
    stage = Stage(
        "watch", binary, sketch_dir, args, log_dir,
        ["watch", "--no-viewer", "--metrics", "--metrics-interval", "0.5"],
    )
    source_file = None
    original = None
    try:
        # 起動の確認はログではなくフレームで行う。初回ビルドが失敗していれば
        # build-status.json が先に落ちてくるので、そちらで打ち切る。
        first = wait_for_fresh_frame(
            sketch_dir,
            since=since,
            timeout=args.build_timeout + args.frame_timeout,
            abort=lambda: stage.child.is_dead() or _initial_build_failed(sketch_dir, since),
        )
        if first is None:
            status = read_build_status(sketch_dir)
            if status is not None and not status[1].get("succeeded", True):
                return stage.fail("初回ビルドに失敗しました", build_failure_detail(status[1]))
            if stage.child.is_dead():
                return stage.fail("watch が終了しました (exit {})".format(stage.child.process.poll()))
            return stage.fail("リロード前に frame.json が出ませんでした")

        source_file = pick_source_file(sketch_dir)
        if source_file is None:
            return stage.fail("Sources/ に .swift が見つかりません (対象スケッチが不適切)")

        edited_at = time.time()
        original = append_reload_marker(
            source_file, "metaphor-cli smoke reload probe {}".format(int(edited_at))
        )

        status = wait_for_build(
            sketch_dir,
            since=edited_at,
            timeout=args.reload_timeout,
            initial=False,
            abort=stage.child.is_dead,
        )
        if status is None:
            return stage.fail(
                "編集しても再ビルドが {}s 以内に起きませんでした "
                "(ファイル監視が止まっています)".format(args.reload_timeout)
            )
        if not status.get("succeeded", False):
            return stage.fail("編集後の再ビルドが失敗しました", build_failure_detail(status))

        # 再ビルドが**終わった後**に書かれたフレームだけを認める。起動時刻や
        # 編集時刻を基準にすると、リロード前に書かれた古いフレームで PASS して
        # しまい、#139 (リロード後にフレームが来ない) を素通りさせる。
        if wait_for_fresh_frame(
            sketch_dir, since=time.time(), timeout=args.frame_timeout, abort=stage.child.is_dead
        ) is None:
            return stage.fail(
                "リロードは起きましたが、その後に新しい frame.json が来ませんでした "
                "(#139 と同じ症状)"
            )

        return stage.ok("リロード後のフレーム到達")
    finally:
        if source_file is not None and original is not None:
            restore_source(source_file, original)
        stage.stop()


def _initial_build_failed(sketch_dir, since):
    status = read_build_status(sketch_dir)
    if status is None:
        return False
    mtime, payload = status
    return mtime > since and not payload.get("succeeded", True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=REPO_DEFAULT, help="作品リポジトリ (既定: %(default)s)")
    parser.add_argument("--ref", default="main", help="作品リポジトリの ref (既定: %(default)s)")
    parser.add_argument("--sketch", default=SKETCH_DEFAULT, help="作品のパス (既定: %(default)s)")
    parser.add_argument("--sketch-dir", help="手元のスケッチを使う (clone しない)")
    parser.add_argument("--metaphor-bin", help="使う metaphor バイナリ (既定: .build/debug/metaphor)")
    parser.add_argument("--only", choices=("run", "watch"), help="片方だけ実行する")
    parser.add_argument("--headless", action="store_true",
                        help="子へ METAPHOR_VIEWER=1 を渡して窓を開かせない")
    parser.add_argument("--keep", action="store_true", help="作業ディレクトリを消さない")
    # 既定値は GH の macos-26 ランナーでの実測から。3 回連続で
    # run（clone + metaphor のコールドビルド + 初回フレーム）が 29.0 / 31.1 / 50.0 秒、
    # watch（起動 + 編集 + 再ビルド + フレーム）が 5.3 / 6.3 / 11.6 秒だったので、
    # いずれも最悪値の 10 倍以上を積んである。締めすぎると遅いランナーで偽陽性、
    # 緩めすぎると「ハングしているのに 10 分黙る」失敗になる。
    parser.add_argument("--build-timeout", type=float, default=900.0,
                        help="初回ビルドの待ち上限 (秒, 既定: %(default)s)")
    parser.add_argument("--frame-timeout", type=float, default=120.0,
                        help="フレーム 1 枚の待ち上限 (秒, 既定: %(default)s)")
    parser.add_argument("--reload-timeout", type=float, default=300.0,
                        help="編集からリロードまでの待ち上限 (秒, 既定: %(default)s)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    repo_root = Path(__file__).resolve().parents[1]
    binary = resolve_binary(args.metaphor_bin, repo_root)

    workdir = Path(tempfile.mkdtemp(prefix="metaphor-smoke-"))
    log_dir = workdir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    print("スモーク作業ディレクトリ: {}".format(workdir))
    print("使用する CLI: {}".format(binary))

    try:
        if args.sketch_dir:
            sketch_dir = Path(args.sketch_dir).expanduser().resolve()
            if not (sketch_dir / "Package.swift").exists():
                raise SystemExit("Package.swift がありません: {}".format(sketch_dir))
        else:
            sketch_dir = checkout_sketch(args.repo, args.ref, args.sketch, workdir / "sketches")
        print("対象スケッチ: {}".format(sketch_dir))

        # 前回の残骸で PASS しないよう Probe の出力を消してから始める。
        shutil.rmtree(sketch_dir / ".metaphor", ignore_errors=True)

        results = []
        if args.only in (None, "run"):
            results.append(("run", smoke_run(binary, sketch_dir, args, log_dir)))
        if args.only in (None, "watch"):
            results.append(("watch", smoke_watch(binary, sketch_dir, args, log_dir)))

        failed = [name for name, ok in results if not ok]
        for name, ok in results:
            print("{}: {}".format(name, "PASS" if ok else "FAIL"))
        if failed:
            print("::error::スモーク失敗: {}".format(", ".join(failed)), file=sys.stderr)
            return 1
        return 0
    finally:
        if args.keep:
            print("作業ディレクトリを残しました: {}".format(workdir))
        else:
            # ログは CI が artifact に集めるので、消す前にリポジトリ直下へ移す。
            keep_logs = repo_root / ".smoke-logs"
            shutil.rmtree(keep_logs, ignore_errors=True)
            if log_dir.exists():
                shutil.copytree(log_dir, keep_logs)
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
