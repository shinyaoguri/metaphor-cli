#!/usr/bin/env python3
"""metaphor-cli の最新リリースが Homebrew まで届いたかを一点で監査する。

metaphor-cli のリリースが `brew install shinyaoguri/tap/metaphor` のユーザーに
届くには、release.yml が homebrew-tap へ Formula 更新の PR を出し、tap 側の
brew test-bot が green なら bottle 込みで main へ入る、という受け渡しがある。
ここが止まっても cli 側の Release workflow は「成功したまま」に見える。

この監査は最終地点(tap の Formula)から逆算して「届いたかどうか」だけを見るので、
PR 作成・test-bot・pr-pull のどこで止まっても同じ 1 本で捕まる。

かつては metaphor(ライブラリ) の Syphon pin が cli を経由して届くまでの 4 段
(dispatch → pin bump PR → cli リリース → tap) を見ていたが、ライブビューアが
frame IPC へ移って Syphon pin の契約 (契約点 1) と自動 bump が無くなったので
(metaphor#792 / docs/decisions/0014)、最後の 1 段だけが残った。

healthy な状態:

    tap の Formula が指す cli タグ == cli の最新リリース

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

CLI_REPO = "shinyaoguri/metaphor-cli"
TAP_REPO = "shinyaoguri/homebrew-tap"
TAP_FORMULA_PATH = "Formula/metaphor.rb"

# Issue の重複作成を防ぐための目印。監査が自分で作った Issue だけを探して閉じる。
AUDIT_LABEL = "release-pipeline"

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
    """cli リリース → tap の受け渡しの現在地。"""

    def __init__(self) -> None:
        cli = gh_json("api", f"repos/{CLI_REPO}/releases/latest")
        self.cli_tag: str = cli["tag_name"]
        self.cli_published: str = cli["published_at"]

        self.tap_tag = extract(
            FORMULA_TAG_RE,
            file_at(TAP_REPO, TAP_FORMULA_PATH),
            "tap の Formula が指す cli タグ",
        )

    @property
    def lag_hours(self) -> float:
        return hours_since(self.cli_published)

    def stalled_stage(self) -> str | None:
        """詰まっている箇所。届いていれば None。"""
        if self.tap_tag != self.cli_tag:
            return (
                f"metaphor-cli {self.cli_tag} は出ているが、homebrew-tap の "
                f"Formula は {self.tap_tag} を指したままです。"
                " tap への PR 作成・brew test-bot・pr-pull のどれかで止まっています。"
            )
        return None

    def table(self) -> str:
        return "\n".join(
            [
                "| 見ているもの | 値 |",
                "| --- | --- |",
                f"| metaphor-cli の最新リリース | `{self.cli_tag}` |",
                f"| homebrew-tap の Formula が指す版 | `{self.tap_tag}` |",
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
    return f"release pipeline: metaphor-cli {audit.cli_tag} が Homebrew まで届いていない"


def report(audit: Audit, stalled: str, max_lag_hours: float) -> None:
    title = issue_title(audit)
    existing = open_audit_issues()
    if any(issue["title"] == title for issue in existing):
        print(f"既に起票済み: {title}")
        return

    body = f"""{stalled}

metaphor-cli **{audit.cli_tag}** の公開から {audit.lag_hours:.0f} 時間
（しきい値 {max_lag_hours:.0f} 時間）が経っていますが、`brew install shinyaoguri/tap/metaphor`
にはまだ届いていません。

{audit.table()}

この Issue は `scripts/audit-release-pipeline.py`（`release-pipeline-audit.yml`）が
自動起票したもので、Formula が最新リリースを指した次の監査で自動的にクローズされます。

### 手で進めるなら

```bash
# tap の PR（release.yml が出したもの）の状態を確認する
gh pr list --repo {TAP_REPO}

# PR が無ければ、cli のリリースを出し直して Formula PR を作り直す
gh workflow run release.yml --repo {CLI_REPO} -f bump=patch
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
            f"metaphor-cli `{audit.cli_tag}` が homebrew-tap まで届いたことを確認したため"
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
        print(f"healthy: metaphor-cli {audit.cli_tag} は homebrew-tap まで届いています。")
        if not args.dry_run:
            resolve(audit)
        return 0

    print(stalled)
    print(f"経過: {audit.lag_hours:.1f} 時間 / しきい値 {args.max_lag_hours:.0f} 時間")

    if audit.lag_hours <= args.max_lag_hours:
        # まだ配送中でありうる時間帯（tap の test-bot と bottle の公開に数時間かかる）。
        print("しきい値内のため、まだ配送中とみなして起票しません。")
        return 0

    if args.dry_run:
        print("--dry-run のため起票しません。")
        return 0

    report(audit, stalled, args.max_lag_hours)
    return 0


if __name__ == "__main__":
    sys.exit(main())
