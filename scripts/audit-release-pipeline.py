#!/usr/bin/env python3
"""metaphor の安定版リリースが Homebrew まで届いたかを一点で監査する。

metaphor(ライブラリ) の安定版が `brew install shinyaoguri/tap/metaphor` の
ユーザーに届くまでには 4 つの受け渡しがある:

    1. metaphor の release.yml が repository_dispatch を撃つ
       (取りこぼしは syphon-bump.yml の週次 poll が拾う)
    2. syphon-bump.yml が Package.swift の Syphon pin を上げる PR を出し、
       auto-merge で main へ入れる
    3. その PR の `release:patch` ラベルで release-on-merge.yml が発火し、
       metaphor-cli の新しいリリースが出る
    4. release.yml が homebrew-tap へ Formula 更新の PR を出し、tap 側の
       brew test-bot が green なら bottle 込みで main へ入る

どの段も、止まったとき前後の段は「成功したまま」に見える。実際 dispatch は
CLI_DISPATCH_TOKEN が未設定のまま v0.9.0 まで一度も発火せず、リリースは毎回
緑だった。この監査は最終地点(tap の Formula)から逆算し、詰まっている段を名指し
して Issue に残す。個々のワークフローの成否ではなく「届いたかどうか」だけを見る
ので、まだ知らない壊れ方も同じ 1 本で捕まる。

healthy な状態:

    tap の Formula が指す cli タグ == cli の最新リリース
    かつ そのリリース時点の Package.swift の Syphon pin == metaphor の最新安定版

usage:
    python3 scripts/audit-release-pipeline.py            # 監査して Issue を出す
    python3 scripts/audit-release-pipeline.py --dry-run  # 判定だけ表示する
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

LIBRARY_REPO = "shinyaoguri/metaphor"
CLI_REPO = "shinyaoguri/metaphor-cli"
TAP_REPO = "shinyaoguri/homebrew-tap"
TAP_FORMULA_PATH = "Formula/metaphor.rb"

# Issue の重複作成を防ぐための目印。監査が自分で作った Issue だけを探して閉じる。
AUDIT_LABEL = "release-pipeline"

# metaphor-cli/Package.swift が binaryTarget として指す Syphon の Release URL。
SYPHON_PIN_RE = re.compile(r"releases/download/(v[^/\"]+)/Syphon\.xcframework\.zip")
# Formula が source tarball として指す metaphor-cli の Release URL。
FORMULA_TAG_RE = re.compile(r"metaphor-cli/releases/download/(v[^/\"]+)/")


def gh(*args: str) -> str:
    """gh を呼んで stdout を返す。失敗はそのまま例外にする(監査の沈黙を避ける)。"""
    result = subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True
    )
    return result.stdout


def gh_json(*args: str):
    return json.loads(gh(*args))


def file_at(repo: str, path: str, ref: str | None = None) -> str:
    """リポジトリ上のファイルを取得する。ref を渡すとそのタグ/SHA 時点の内容。"""
    query = f"repos/{repo}/contents/{path}"
    if ref:
        query += f"?ref={ref}"
    payload = gh_json("api", query)
    return base64.b64decode(payload["content"]).decode()


def extract(pattern: re.Pattern[str], text: str, what: str) -> str:
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"error: {what} を読み取れませんでした（形式が変わった可能性があります）")
    return match.group(1)


def hours_since(timestamp: str) -> float:
    published = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - published).total_seconds() / 3600


class Audit:
    """4 段の受け渡しの現在地。"""

    def __init__(self) -> None:
        library = gh_json("api", f"repos/{LIBRARY_REPO}/releases/latest")
        self.library_tag: str = library["tag_name"]
        self.library_published: str = library["published_at"]

        cli = gh_json("api", f"repos/{CLI_REPO}/releases/latest")
        self.cli_tag: str = cli["tag_name"]

        self.pin_on_main = extract(
            SYPHON_PIN_RE, file_at(CLI_REPO, "Package.swift"), "main の Syphon pin"
        )
        self.pin_at_cli_release = extract(
            SYPHON_PIN_RE,
            file_at(CLI_REPO, "Package.swift", ref=self.cli_tag),
            f"{self.cli_tag} 時点の Syphon pin",
        )
        self.tap_tag = extract(
            FORMULA_TAG_RE,
            file_at(TAP_REPO, TAP_FORMULA_PATH),
            "tap の Formula が指す cli タグ",
        )

    @property
    def lag_hours(self) -> float:
        return hours_since(self.library_published)

    def stalled_stage(self) -> str | None:
        """最初に詰まっている段。全段通っていれば None。"""
        if self.pin_on_main != self.library_tag:
            return (
                f"段 1-2: metaphor {self.library_tag} の Syphon pin が metaphor-cli の "
                f"main に入っていない（main は {self.pin_on_main}）。"
                " dispatch が撃たれなかったか、syphon-bump.yml の PR が作られていないか"
                " 未 merge のまま止まっています。"
            )
        if self.pin_at_cli_release != self.library_tag:
            return (
                f"段 3: pin は main まで来ている（{self.pin_on_main}）が、それを載せた "
                f"metaphor-cli のリリースが出ていない（最新 {self.cli_tag} は "
                f"{self.pin_at_cli_release} を pin）。"
                " release-on-merge.yml が発火しなかった可能性があります"
                "（pin bump PR の `release:patch` ラベル欠落など）。"
            )
        if self.tap_tag != self.cli_tag:
            return (
                f"段 4: metaphor-cli {self.cli_tag} は出ているが、homebrew-tap の "
                f"Formula は {self.tap_tag} を指したままです。"
                " tap への PR 作成・brew test-bot・pr-pull のどれかで止まっています。"
            )
        return None

    def table(self) -> str:
        return "\n".join(
            [
                "| 段 | 見ているもの | 値 |",
                "| --- | --- | --- |",
                f"| — | metaphor の最新安定版 | `{self.library_tag}` |",
                f"| 1-2 | metaphor-cli main の Syphon pin | `{self.pin_on_main}` |",
                f"| 3 | metaphor-cli の最新リリース | `{self.cli_tag}` |",
                f"| 3 | そのリリース時点の Syphon pin | `{self.pin_at_cli_release}` |",
                f"| 4 | homebrew-tap の Formula が指す版 | `{self.tap_tag}` |",
            ]
        )


def ensure_label() -> None:
    subprocess.run(
        [
            "gh", "label", "create", AUDIT_LABEL,
            "--repo", CLI_REPO,
            "--color", "B60205",
            "--description", "リリースが Homebrew まで届いていない",
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def open_audit_issues() -> list[dict]:
    return gh_json(
        "issue", "list",
        "--repo", CLI_REPO,
        "--label", AUDIT_LABEL,
        "--state", "open",
        "--json", "number,title",
    )


def issue_title(audit: Audit) -> str:
    return f"release pipeline: metaphor {audit.library_tag} が Homebrew まで届いていない"


def report(audit: Audit, stalled: str, max_lag_hours: float) -> None:
    title = issue_title(audit)
    existing = open_audit_issues()
    if any(issue["title"] == title for issue in existing):
        print(f"既に起票済み: {title}")
        return

    body = f"""{stalled}

metaphor **{audit.library_tag}** の公開から {audit.lag_hours:.0f} 時間
（しきい値 {max_lag_hours:.0f} 時間）が経っていますが、`brew install shinyaoguri/tap/metaphor`
にはまだ届いていません。

{audit.table()}

この Issue は `scripts/audit-release-pipeline.py`（`release-pipeline-audit.yml`）が
自動起票したもので、4 段すべてが揃った次の監査で自動的にクローズされます。

### 手で進めるなら

```bash
# 段 1-2: pin bump をやり直す
gh workflow run syphon-bump.yml --repo {CLI_REPO} -f tag={audit.library_tag}

# 段 3: pin は main にあるがリリースが無いとき
gh workflow run release.yml --repo {CLI_REPO} -f bump=patch

# 段 4: tap の PR を確認する
gh pr list --repo {TAP_REPO}
```
"""
    ensure_label()
    url = gh(
        "issue", "create",
        "--repo", CLI_REPO,
        "--title", title,
        "--body", body,
        "--label", AUDIT_LABEL,
    ).strip()
    print(f"起票しました: {url}")


def resolve(audit: Audit) -> None:
    """健全化したら、監査が残した Issue を閉じる（自己修復も記録として残す）。"""
    for issue in open_audit_issues():
        gh(
            "issue", "close", str(issue["number"]),
            "--repo", CLI_REPO,
            "--comment",
            f"metaphor `{audit.library_tag}` が homebrew-tap まで届いたことを確認したため"
            f"自動でクローズします。\n\n{audit.table()}",
        )
        print(f"クローズしました: #{issue['number']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--max-lag-hours",
        type=float,
        default=48.0,
        help="この時間を超えて未達なら Issue を起票する（既定: 48）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Issue を作らず判定だけ表示する",
    )
    args = parser.parse_args()

    audit = Audit()
    print(audit.table())
    print()

    stalled = audit.stalled_stage()
    if stalled is None:
        print(f"healthy: metaphor {audit.library_tag} は homebrew-tap まで届いています。")
        if not args.dry_run:
            resolve(audit)
        return 0

    print(stalled)
    print(f"経過: {audit.lag_hours:.1f} 時間 / しきい値 {args.max_lag_hours:.0f} 時間")

    if audit.lag_hours <= args.max_lag_hours:
        # まだ配送中でありうる時間帯。ここで騒ぐと週次トレインの当日に必ず鳴る。
        print("しきい値内のため、まだ配送中とみなして起票しません。")
        return 0

    if args.dry_run:
        print("--dry-run のため起票しません。")
        return 0

    report(audit, stalled, args.max_lag_hours)
    return 0


if __name__ == "__main__":
    sys.exit(main())
