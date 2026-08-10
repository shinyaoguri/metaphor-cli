#!/bin/bash
# PostToolUse(Bash) hook — `git push` を見たら「この PR の CI を見届ける」印を置く。
#
# 印があるときだけ ci-watch-stop.sh が CI を確認する。push していないセッション
# （調べもの・ローカル編集だけ）で GitHub を叩かないための入口ガード。
#
# stdin: PostToolUse の JSON（.tool_input.command / .cwd）
# 出力なし・常に exit 0（この hook は判断を下さない）
set -uo pipefail

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
case "$cmd" in
    *"git push"*) ;;
    *) exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
[ -n "$cwd" ] && [ -n "$session" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

branch=$(git branch --show-current 2>/dev/null) || exit 0
[ -n "$branch" ] || exit 0
# main は PR を経由しない（ルールセットで直接 push 不可）ので見張らない
[ "$branch" = "main" ] && exit 0

# worktree からでも同じ場所を指すよう common-dir を使う。セッション ID で分離するので
# 並行セッション同士は衝突しない。
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
dir="$git_dir/claude-ci-watch"
mkdir -p "$dir" 2>/dev/null || exit 0
printf 'branch=%s\nfixes=0\nwaits=0\n' "$branch" > "$dir/$session"

exit 0
