#!/usr/bin/env bash
#
# Cross-repo byte-identity check (metaphor <-> metaphor-cli).
#
# The contract between the two repositories is carried by files that are
# declared "kept identical in both repositories" (CONTRACT.md and
# contract/README.md). The token-presence check in check-contract.sh does NOT
# catch the case where such a file is edited on only one side, so this script
# downloads each of them from the other repo and diffs it against the local
# copy. The identity set (Issue #139):
#
#   - CONTRACT.md
#   - contract/**  (README.md, *.schema.json, examples/*.json)
#   - scripts/check-contract.sh
#   - scripts/check-contract-schema.sh
#   - scripts/check-contract-identity.sh  (this script itself)
#
# The contract/ part of the list is the UNION of both repositories' listings,
# so a file added or deleted on only one side is reported as well.
#
# Coordinated edits: a change to any of these files must land in both repos
# together. To avoid a deadlock where each PR's CI compares against the other
# repo's (still old) default branch, we first try the sibling repo's branch
# with the SAME name as the current branch, and only fall back to its default
# branch. Note the push-to-main CI run of whichever repo merges FIRST still
# compares against the other repo's old default branch and fails — merge the
# paired PRs back to back and re-run that one job.
#
# Requires the `gh` CLI authenticated (GITHUB_TOKEN is available by default in
# GitHub Actions). Run from either repository — it auto-detects which one.
#
# This script is kept IDENTICAL in both repositories. If you edit it, copy the
# change to the other repo too (CI enforces this).
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

if ! command -v gh >/dev/null 2>&1; then
  echo "warning: gh CLI not found — skipping cross-repo identity check."
  exit 0
fi

# Current branch: prefer the CI-provided PR head, else the local git branch.
BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"

# Resolve the comparison ref ONCE so every file comes from the same ref: the
# sibling repo's same-named branch if it exists, else its default branch.
REF=""
source_desc="$OTHER_REPO (default branch)"
if [ -n "$BRANCH" ] && gh api "repos/$OTHER_REPO/branches/$BRANCH" --jq '.name' >/dev/null 2>&1; then
  REF="$BRANCH"
  source_desc="$OTHER_REPO@$BRANCH"
fi

# gh api path for a file or directory at the resolved ref.
api_path() {
  local p="repos/$OTHER_REPO/contents/$1"
  [ -n "$REF" ] && p="$p?ref=$REF"
  printf '%s' "$p"
}

# List the files directly under a directory on the other repo (no recursion).
list_remote_dir() {
  gh api "$(api_path "$1")" --jq '.[] | select(.type == "file") | .path' 2>/dev/null || true
}

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.err"' EXIT

# Fetch one file from the other repo into $tmp. Succeeds only on a non-empty
# result (none of the identity files is legitimately empty).
#
# Transient API failures (5xx, secondary rate limits, network) are retried a
# few times with backoff so that a single flaky call cannot fail CI
# (metaphor#244 / metaphor-cli#66). HTTP 404 is a definitive "missing on the
# other side" and is NOT retried. Return codes: 0 = fetched, 1 = missing
# (404), 2 = still failing after retries (transient).
fetch_remote() {
  local path="$1" attempt
  for attempt in 1 2 3; do
    if gh api "$(api_path "$path")" --jq '.content' 2>"$tmp.err" | base64 -d > "$tmp" 2>/dev/null \
        && [ -s "$tmp" ]; then
      return 0
    fi
    if grep -q 'HTTP 404' "$tmp.err" 2>/dev/null; then
      return 1
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep "$attempt"
    fi
  done
  return 2
}

# Connectivity probe: CONTRACT.md exists in both repos on every ref. If it
# cannot be fetched at all, degrade to a warning (auth/network/visibility)
# instead of failing, matching the original CONTRACT.md-only check.
if ! fetch_remote "CONTRACT.md"; then
  echo "warning: could not fetch CONTRACT.md from $source_desc (auth/network/visibility?) — skipping identity check."
  echo "         To enable this check for private repos, provide a token with read access to $OTHER_REPO."
  exit 0
fi

FILES="$(
  {
    printf '%s\n' \
      CONTRACT.md \
      scripts/check-contract.sh \
      scripts/check-contract-schema.sh \
      scripts/check-contract-identity.sh
    find contract -type f 2>/dev/null || true
    list_remote_dir contract
    list_remote_dir contract/examples
  } | sort -u
)"

failures=0
while IFS= read -r file; do
  if [ ! -f "$file" ]; then
    echo "::error::$file exists in $source_desc but not in this repository."
    failures=$((failures + 1))
    continue
  fi
  rc=0
  fetch_remote "$file" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "::error::$file exists in this repository but is missing from $source_desc (HTTP 404). Sync both repos (see CONTRACT.md change rules)."
    failures=$((failures + 1))
    continue
  elif [ "$rc" -ne 0 ]; then
    echo "::error::$file could not be fetched from $source_desc after retries (transient API error — NOT necessarily missing on the other side). Re-run this job."
    failures=$((failures + 1))
    continue
  fi
  if diff -q "$file" "$tmp" >/dev/null; then
    echo "ok: $file is byte-identical to $source_desc."
  else
    echo "::error::$file differs from $source_desc. Sync both repos (see CONTRACT.md change rules)."
    echo "--- diff: $file (local vs $source_desc) ---"
    diff "$file" "$tmp" || true
    failures=$((failures + 1))
  fi
done <<< "$FILES"

if [ "$failures" -gt 0 ]; then
  echo "::error::$failures file(s) violate cross-repo byte-identity with $source_desc."
  exit 1
fi

echo "All shared contract files are byte-identical to $source_desc."
