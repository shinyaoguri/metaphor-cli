#!/usr/bin/env bash
#
# Cross-repo CONTRACT.md byte-identity check (metaphor <-> metaphor-cli).
#
# CONTRACT.md must be byte-identical in both repositories. The token-presence
# check in check-contract.sh does NOT catch the case where CONTRACT.md itself is
# edited on only one side, so this script downloads the other repo's CONTRACT.md
# and diffs it against the local copy.
#
# Coordinated edits: a CONTRACT.md change must land in both repos together. To
# avoid a deadlock where each PR's CI compares against the other repo's (still
# old) default branch, we first try the sibling repo's branch with the SAME name
# as the current branch, and only fall back to its default branch.
#
# Requires the `gh` CLI authenticated (GITHUB_TOKEN is available by default in
# GitHub Actions). Run from either repository — it auto-detects which one.
#
# This script is kept IDENTICAL in both repositories. If you edit it, copy the
# change to the other repo too.
#
set -euo pipefail

cd "$(dirname "$0")/.."

OWNER="shinyaoguri"

# Detect which repository we are in from the SwiftPM package name, and pick the
# OTHER repo to compare against.
if grep -q 'name: "metaphor-cli"' Package.swift 2>/dev/null; then
  OTHER_REPO="$OWNER/metaphor"
else
  OTHER_REPO="$OWNER/metaphor-cli"
fi

if [ ! -f CONTRACT.md ]; then
  echo "::error::CONTRACT.md missing in this repository."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "warning: gh CLI not found — skipping cross-repo CONTRACT.md identity check."
  exit 0
fi

# Current branch: prefer the CI-provided PR head, else the local git branch.
BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Fetch CONTRACT.md from the other repo at an optional ref. Writes to $tmp and
# returns success only on a non-empty result.
fetch_contract() {
  local ref="$1" path="repos/$OTHER_REPO/contents/CONTRACT.md"
  [ -n "$ref" ] && path="$path?ref=$ref"
  gh api "$path" --jq '.content' 2>/dev/null | base64 -d > "$tmp" 2>/dev/null
  [ -s "$tmp" ]
}

source_desc=""
if [ -n "$BRANCH" ] && fetch_contract "$BRANCH"; then
  source_desc="$OTHER_REPO@$BRANCH"
elif fetch_contract ""; then
  source_desc="$OTHER_REPO (default branch)"
else
  echo "warning: could not fetch CONTRACT.md from $OTHER_REPO (auth/network/visibility?) — skipping identity check."
  echo "         To enable this check for private repos, provide a token with read access to $OTHER_REPO."
  exit 0
fi

if diff -q CONTRACT.md "$tmp" >/dev/null; then
  echo "CONTRACT.md is byte-identical to $source_desc."
  exit 0
fi

echo "::error::CONTRACT.md differs from $source_desc. Sync both repos (see CONTRACT.md change rules)."
echo "--- diff (local vs $source_desc) ---"
diff CONTRACT.md "$tmp" || true
exit 1
