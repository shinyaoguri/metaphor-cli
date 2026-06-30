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

# check_regex <file> <description> <ERE> — pattern must match somewhere in file.
# Used for format checks (Syphon pin URL/checksum shape) that a substring can't catch.
check_regex() {
  file="$1"; desc="$2"; pat="$3"
  if [ ! -f "$file" ]; then
    echo "::error::contract file missing: $file (REPO=$REPO)"
    fail=1
    return
  fi
  if ! grep -Eq -- "$pat" "$file"; then
    echo "::error::contract format check '$desc' failed in $file"
    echo "          Expected a line matching: $pat"
    echo "          This shape is part of the metaphor <-> metaphor-cli contract (see CONTRACT.md)."
    fail=1
  fi
}

case "$REPO" in
  metaphor)
    # Env vars read by the headless/viewer runtime (contract point 2).
    check "Sources/MetaphorCore/Sketch/SketchRunner.swift" \
      METAPHOR_VIEWER METAPHOR_SYPHON_NAME METAPHOR_FPS METAPHOR_PROBE
    # stdin JSON Lines input: event tags AND field names parsed (contract point 3).
    check "Sources/MetaphorCore/Input/InputInjectionPlugin.swift" \
      mouseDown mouseUp mouseMove mouseDrag scroll keyDown keyUp \
      button code chars repeat dx dy
    # Probe file protocol root path (contract point 4).
    check "Sources/MetaphorCore/Probe/MetaphorProbeConfig.swift" \
      ".metaphor/probe"
    # ProbeRequest fields the consumer writes (contract point 4).
    check "Sources/MetaphorCore/Probe/ProbeRequest.swift" \
      id label scale frames every
    # frame.json schema keys (contract point 4).
    check "Sources/MetaphorCore/Probe/ProbeFrameMetadata.swift" \
      schemaVersion sourceStamp custom customTypes warnings
    # sequence.json schema keys (contract point 4).
    check "Sources/MetaphorCore/Probe/ProbeSequenceManifest.swift" \
      frameCount requestedFrames every frames contactSheet
    # sourceStamp provenance env var read by the probe plugin (contract point 2).
    check "Sources/MetaphorCore/Probe/MetaphorProbePlugin.swift" \
      METAPHOR_SOURCE_STAMP
    # Schema version VALUES — a bump here is a breaking change; CONTRACT.md must move too.
    check "Sources/MetaphorCore/Probe/MetaphorProbePlugin.swift" \
      "schemaVersion: 4" "schemaVersion: 1"
    # Syphon Release dispatch event_type fired to metaphor-cli (auto-bump, L2a).
    check ".github/workflows/release.yml" \
      "event_type=syphon-release"
    # AI docs consumed by metaphor-cli's `api_reference` MCP tool (must exist).
    check "llms.txt"
    check "llms-sketch.txt"
    check "docs/ai/examples-index.md"
    check "docs/ai/examples-index.json"
    ;;
  metaphor-cli)
    # Env vars set when spawning the child sketch (contract point 2).
    check "Sources/MetaphorViewer/ViewerWatch.swift" \
      METAPHOR_VIEWER METAPHOR_SYPHON_NAME METAPHOR_PROBE METAPHOR_FPS
    # METAPHOR_FPS is also wired on the --no-viewer path.
    check "Sources/MetaphorCLICore/WatchCommand.swift" \
      METAPHOR_FPS
    # sourceStamp provenance injected into the child env on every (re)launch (contract point 2).
    check "Sources/MetaphorCLICore/WatchSession.swift" \
      METAPHOR_SOURCE_STAMP
    # stdin JSON Lines input event tags emitted to the child (contract point 3).
    check "Sources/MetaphorViewer/ViewerWindow.swift" \
      mouseDown mouseUp mouseMove mouseDrag scroll keyDown keyUp
    # MCP `input` builder + `capture_sequence` tool: event field names + tool name.
    check "Sources/MetaphorCLICore/MCP/SketchToolHandler.swift" \
      button code chars repeat dx dy capture_sequence
    # Probe request.json is written ATOMICALLY (.tmp -> rename) by both tools (contract point 4).
    check "Sources/MetaphorCLICore/MCP/ProbeSnapshotTool.swift" \
      "request.json.tmp"
    check "Sources/MetaphorCLICore/MCP/ProbeSequenceTool.swift" \
      "request.json.tmp" frames every frameCount contactSheet
    # Syphon.xcframework Release pin (binaryTarget fallback) — presence + format (contract point 1).
    check "Package.swift" \
      "releases/download/v" "checksum:"
    check_regex "Package.swift" "Syphon release URL" \
      "releases/download/v[0-9]+\.[0-9]+\.[0-9]+/Syphon\.xcframework\.zip"
    check_regex "Package.swift" "Syphon checksum (sha256, 64 hex)" \
      "checksum: \"[0-9a-f]{64}\""
    # Syphon Release dispatch event_type received from metaphor (auto-bump, L2a).
    check ".github/workflows/syphon-bump.yml" \
      "syphon-release"
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
