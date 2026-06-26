#!/usr/bin/env bash
#
# Cross-repo contract presence check (metaphor <-> metaphor-cli).
#
# Verifies that every agreed contract token still exists in its expected file.
# A missing token is the usual signature of a rename/removal that silently
# breaks the other repo's live-viewer integration. See CONTRACT.md.
#
# This script is kept IDENTICAL in both repositories (it auto-detects which one
# it is running in). If you edit it, copy the change to the other repo too.
#
set -euo pipefail

cd "$(dirname "$0")/.."

# Detect which repository we are in from the SwiftPM package name.
if grep -q 'name: "metaphor-cli"' Package.swift 2>/dev/null; then
  REPO="metaphor-cli"
else
  REPO="metaphor"
fi

fail=0

# check <file> <token...> — every token must appear (literal substring) in file.
check() {
  file="$1"; shift
  if [ ! -f "$file" ]; then
    echo "::error::contract file missing: $file (REPO=$REPO)"
    fail=1
    return
  fi
  for tok in "$@"; do
    if ! grep -qF -- "$tok" "$file"; then
      echo "::error::contract token '$tok' not found in $file"
      echo "          This token is part of the metaphor <-> metaphor-cli contract."
      echo "          If you renamed/removed it intentionally, update BOTH repos and CONTRACT.md."
      fail=1
    fi
  done
}

case "$REPO" in
  metaphor)
    # Env vars read by the headless/viewer runtime.
    check "Sources/MetaphorCore/Sketch/SketchRunner.swift" \
      METAPHOR_VIEWER METAPHOR_SYPHON_NAME METAPHOR_FPS METAPHOR_PROBE
    # stdin JSON Lines input event tags parsed from the viewer.
    check "Sources/MetaphorCore/Input/InputInjectionPlugin.swift" \
      mouseDown mouseUp mouseMove mouseDrag scroll keyDown keyUp
    # Probe file protocol paths.
    check "Sources/MetaphorCore/Probe/MetaphorProbeConfig.swift" \
      ".metaphor/probe"
    # AI docs consumed by metaphor-cli's `api_reference` MCP tool (must exist).
    check "llms.txt"
    check "llms-sketch.txt"
    check "docs/ai/examples-index.md"
    check "docs/ai/examples-index.json"
    ;;
  metaphor-cli)
    # Env vars set when spawning the child sketch.
    check "Sources/MetaphorViewer/ViewerWatch.swift" \
      METAPHOR_VIEWER METAPHOR_SYPHON_NAME
    # stdin JSON Lines input event tags emitted to the child.
    check "Sources/MetaphorViewer/ViewerWindow.swift" \
      mouseDown mouseUp mouseMove mouseDrag scroll keyDown keyUp
    # Syphon.xcframework Release pin (binaryTarget fallback).
    check "Package.swift" \
      "releases/download/v" "checksum:"
    # AI doc filenames the `api_reference` MCP tool reads from the metaphor package.
    check "Sources/MetaphorCLICore/MCP/MetaphorDocsLocator.swift" \
      "llms.txt"
    check "Sources/MetaphorCLICore/MCP/SketchToolHandler.swift" \
      "llms-sketch.txt" "llms.txt" "docs/ai/examples-index.md"
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Contract check FAILED — see CONTRACT.md for the metaphor <-> metaphor-cli contract."
  exit 1
fi

echo "Contract check passed (REPO=$REPO)."
