#!/bin/bash
# Stop hook — push した PR の CI が赤いまま終わろうとしたら、終わらせずに直させる。
#
# ci-watch-mark.sh が置いた印があるときだけ動く。CI が
#   - 実行中     → 見届けるよう指示して継続（exit 2）
#   - 失敗       → 失敗ジョブとログ取得コマンドを添えて修正を指示（exit 2）
#   - 全部成功   → 印を消して終了（exit 0）
#   - マージ済み / bot の PR / PR 無し → 印を消して終了（exit 0）
#
# 暴走しないよう回数で打ち切る（修正 3 回 / 待機 6 回）。打ち切ったら印を消すので、
# 次に push するまでこの hook は黙る。
#
# stdin: Stop の JSON（.session_id / .cwd）
set -uo pipefail

MAX_FIXES=3
MAX_WAITS=6

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$session" ] && [ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
marker="$git_dir/claude-ci-watch/$session"
[ -f "$marker" ] || exit 0

branch=$(sed -n 's/^branch=//p' "$marker")
fixes=$(sed -n 's/^fixes=//p' "$marker")
waits=$(sed -n 's/^waits=//p' "$marker")
[ -n "$branch" ] || { rm -f "$marker"; exit 0; }
fixes=${fixes:-0}
waits=${waits:-0}

pr=$(gh pr view "$branch" --json number,state,url,author,statusCheckRollup 2>/dev/null) || {
    # PR がまだ無い（push しただけ）／取得できない — 見張る対象が無いので黙って終わる
    rm -f "$marker"
    exit 0
}

state=$(printf '%s' "$pr" | jq -r '.state // ""')
if [ "$state" != "OPEN" ]; then
    rm -f "$marker"
    exit 0
fi

# 自分の PR だけを対象にする（dependabot / Syphon pin bump などの bot PR は触らない）
author=$(printf '%s' "$pr" | jq -r '.author.login // ""')
case "$author" in
    *"[bot]"|dependabot|github-actions) rm -f "$marker"; exit 0 ;;
esac

number=$(printf '%s' "$pr" | jq -r '.number')
url=$(printf '%s' "$pr" | jq -r '.url')

# statusCheckRollup は CheckRun（status/conclusion）と StatusContext（state）が混在する
failed=$(printf '%s' "$pr" | jq -r '
    [.statusCheckRollup[]?
     | select(
         ((.conclusion // "") | test("^(FAILURE|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED|CANCELLED)$"))
         or ((.state // "") | test("^(FAILURE|ERROR)$")))
     | "- \(.name // .context // "check") — \(.detailsUrl // .targetUrl // "")"]
    | join("\n")')
pending=$(printf '%s' "$pr" | jq -r '
    [.statusCheckRollup[]?
     | select(
         ((.status // "") | test("^(QUEUED|IN_PROGRESS|PENDING|WAITING)$"))
         or ((.state // "") | test("^PENDING$")))]
    | length')

if [ -n "$failed" ]; then
    if [ "$fixes" -ge "$MAX_FIXES" ]; then
        # 自動修正の打ち切り。次の push まで黙る（人間の判断へ返す）
        rm -f "$marker"
        exit 0
    fi
    printf 'branch=%s\nfixes=%s\nwaits=%s\n' "$branch" "$((fixes + 1))" "$waits" > "$marker"
    cat >&2 <<EOF
PR #$number ($branch) の CI が赤いままです（自動修正 $((fixes + 1))/$MAX_FIXES 回目）。終了せず直してください。

失敗したチェック:
$failed

手順:
1. 失敗ログを読む（ジョブ URL 末尾の数字が job id）:
   gh run view --job <job-id> --log-failed | tail -80
2. 原因を直す。ローカル検証: make test（契約に触れたなら make contract も）
3. 修正をコミットして push（この PR のブランチへ追加コミット）。

注意:
- 直す対象は「今回の変更が壊したもの」に限る。無関係な既存の赤や flaky が原因だと
  分かったら、直さずに状況を報告して終えてよい（この hook は $MAX_FIXES 回で自動的に黙ります）。
- テストを削る・skip する・アサーションを緩めるといった「赤を消すだけ」の対処はしない。
- PR: $url
EOF
    exit 2
fi

if [ "$pending" -gt 0 ]; then
    if [ "$waits" -ge "$MAX_WAITS" ]; then
        rm -f "$marker"
        exit 0
    fi
    printf 'branch=%s\nfixes=%s\nwaits=%s\n' "$branch" "$fixes" "$((waits + 1))" > "$marker"
    cat >&2 <<EOF
PR #$number ($branch) の CI がまだ実行中です（$pending 件）。結果を見届けてから終えてください。

  gh pr checks $number --watch --interval 20

green ならそのまま終了して構いません（auto-merge 済みならマージされます）。赤なら失敗ログを読んで直してください。
EOF
    exit 2
fi

# 全部 green（または該当チェック無し）
rm -f "$marker"
exit 0
