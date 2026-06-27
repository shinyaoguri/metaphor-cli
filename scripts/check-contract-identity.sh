#!/usr/bin/env bash
#
# Cross-repo CONTRACT.md byte-identity check (metaphor <-> metaphor-cli).
#
# CONTRACT.md must be byte-identical in both repositories. The token-presence
# check in check-contract.sh does NOT catch the case where CONTRACT.md itself is
# edited on only one side, so this script downloads the other repo's CONTRACT.md
# and diffs it against the local copy.
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

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Fetch the other repo's CONTRACT.md (base64-decoded contents API).
# A fetch failure (private repo, token scope, network) is treated as a
# non-fatal SKIP so infra issues don't break CI; only a real diff fails.
if ! gh api "repos/$OTHER_REPO/contents/CONTRACT.md" --jq '.content' 2>/dev/null \
  | base64 -d > "$tmp"; then
  echo "warning: could not fetch CONTRACT.md from $OTHER_REPO (auth/network/visibility?) — skipping identity check."
  echo "         To enable this check for private repos, provide a token with read access to $OTHER_REPO."
  exit 0
fi

# An empty fetch (unexpected API shape) is also a skip rather than a false diff.
if [ ! -s "$tmp" ]; then
  echo "warning: fetched CONTRACT.md from $OTHER_REPO was empty — skipping identity check."
  exit 0
fi

if diff -q CONTRACT.md "$tmp" >/dev/null; then
  echo "CONTRACT.md is byte-identical to $OTHER_REPO."
  exit 0
fi

echo "::error::CONTRACT.md differs from $OTHER_REPO. Sync both repos (see CONTRACT.md change rules)."
echo "--- diff (local vs $OTHER_REPO) ---"
diff CONTRACT.md "$tmp" || true
exit 1
