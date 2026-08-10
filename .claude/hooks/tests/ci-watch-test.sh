#!/bin/bash
# ci-watch-mark.sh / ci-watch-stop.sh の分岐テスト。
#
#   .claude/hooks/tests/ci-watch-test.sh
#
# 使い捨ての git リポと、固定 JSON を返す `gh` スタブで hook を直接叩く。
# GitHub にも Claude セッションにも触らないので、いつでも安全に走らせられる。
set -uo pipefail

hooks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mark_hook="$hooks_dir/ci-watch-mark.sh"
stop_hook="$hooks_dir/ci-watch-stop.sh"

pass=0
fail=0

# 使い捨てリポ + gh スタブ
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
repo="$sandbox/repo"
mkdir -p "$repo" "$sandbox/bin"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$repo" checkout -q -b feature/x

cat > "$sandbox/bin/gh" <<'STUB'
#!/bin/bash
[ "${GH_STUB_EXIT:-0}" = "0" ] || exit "$GH_STUB_EXIT"
cat "$GH_STUB_JSON"
STUB
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"

marker_dir="$repo/.git/claude-ci-watch"
marker="$marker_dir/sess1"

# --- ヘルパー ---------------------------------------------------------------

# ロールアップの JSON を書き出す
rollup() { printf '%s' "$1" > "$sandbox/pr.json"; export GH_STUB_JSON="$sandbox/pr.json"; }

put_marker() {
    mkdir -p "$marker_dir"
    printf 'branch=feature/x\nfixes=%s\nwaits=%s\n' "${1:-0}" "${2:-0}" > "$marker"
}

run_stop() {
    printf '{"session_id":"sess1","cwd":"%s"}' "$repo" | "$stop_hook" 2>"$sandbox/err"
    echo $?
}

run_mark() {
    printf '{"session_id":"sess1","cwd":"%s","tool_input":{"command":"%s"}}' "$repo" "$1" \
        | "$mark_hook" >/dev/null 2>&1
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        printf '  ok   %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL %s — expected [%s], got [%s]\n' "$label" "$expected" "$actual"
        [ -s "$sandbox/err" ] && sed 's/^/       | /' "$sandbox/err"
    fi
}

open_pr() {  # $1 = statusCheckRollup の中身, $2 = author（省略時は人間）
    cat <<EOF
{"number":1,"state":"OPEN","url":"https://example.com/pr/1",
 "author":{"login":"${2:-shinyaoguri}"},
 "statusCheckRollup":[$1]}
EOF
}

green='{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"u"}'
red='{"__typename":"CheckRun","name":"build-and-test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://example.com/job/42"}'
running='{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"u"}'
red_context='{"__typename":"StatusContext","context":"legacy","state":"FAILURE","targetUrl":"u"}'

echo "ci-watch hooks"

# --- Stop hook --------------------------------------------------------------

rm -rf "$marker_dir"
rollup "$(open_pr "$red")"
check "印が無ければ何もしない" 0 "$(run_stop)"

put_marker
check "CI 失敗 → 継続させる" 2 "$(run_stop)"
check "  失敗ジョブ名を伝える" 0 "$(grep -qc 'build-and-test' "$sandbox/err" >/dev/null; echo $?)"
check "  ジョブ URL を伝える" 0 "$(grep -qc 'example.com/job/42' "$sandbox/err" >/dev/null; echo $?)"
check "  修正回数を数える" "fixes=1" "$(sed -n 's/^\(fixes=.*\)/\1/p' "$marker")"

put_marker 3 0
check "修正 3 回で打ち切る" 0 "$(run_stop)"
check "  打ち切ったら印を消す" "absent" "$([ -f "$marker" ] && echo present || echo absent)"

put_marker
rollup "$(open_pr "$red_context")"
check "StatusContext 形式の失敗も拾う" 2 "$(run_stop)"

put_marker
rollup "$(open_pr "$running,$green")"
check "CI 実行中 → 見届けさせる" 2 "$(run_stop)"
check "  待機回数を数える" "waits=1" "$(sed -n 's/^\(waits=.*\)/\1/p' "$marker")"

put_marker 0 6
check "待機 6 回で打ち切る" 0 "$(run_stop)"

put_marker
rollup "$(open_pr "$green")"
check "CI 全部 green → 終わってよい" 0 "$(run_stop)"
check "  green なら印を消す" "absent" "$([ -f "$marker" ] && echo present || echo absent)"

put_marker
rollup "$(open_pr "$red" "dependabot[bot]")"
check "bot の PR は触らない" 0 "$(run_stop)"

put_marker
rollup '{"number":1,"state":"MERGED","url":"u","author":{"login":"shinyaoguri"},"statusCheckRollup":[]}'
check "マージ済みなら終わってよい" 0 "$(run_stop)"

put_marker
GH_STUB_EXIT=1 && export GH_STUB_EXIT
check "PR がまだ無いなら黙る" 0 "$(run_stop)"
unset GH_STUB_EXIT

# --- PostToolUse hook -------------------------------------------------------

rm -rf "$marker_dir"
run_mark "swift test"
check "push 以外では印を置かない" "absent" "$([ -f "$marker" ] && echo present || echo absent)"

run_mark "git push -u origin feature/x"
check "push したら印を置く" "present" "$([ -f "$marker" ] && echo present || echo absent)"
check "  ブランチを記録する" "branch=feature/x" "$(sed -n 's/^\(branch=.*\)/\1/p' "$marker")"

rm -rf "$marker_dir"
git -C "$repo" checkout -q main
run_mark "git push"
check "main では印を置かない" "absent" "$([ -f "$marker" ] && echo present || echo absent)"
git -C "$repo" checkout -q feature/x

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
