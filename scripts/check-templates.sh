#!/usr/bin/env bash
#
# Template freshness check (metaphor-cli only).
#
# `metaphor new` scaffolds an AGENTS.md that points agents at the dependency's
# metaphor docs (llms.txt etc.). Those filenames are the SAME ones the
# `api_reference` MCP tool serves. If a doc is renamed/removed and only one side
# is updated, `metaphor new` keeps emitting dangling doc links while runtime
# `api_reference` silently changes — a slow drift between the template and the
# library docs. This check fails when the template references a doc that the
# `api_reference` tool does not serve.
#
# Deliberately NOT shared with the other repo (templates live only here).
#
set -euo pipefail

cd "$(dirname "$0")/.."

HANDLER="Sources/MetaphorCLICore/MCP/SketchToolHandler.swift"
TMPL="Templates/common/AGENTS.md.template"
fail=0

[ -f "$HANDLER" ] || { echo "::error::missing $HANDLER"; exit 1; }
[ -f "$TMPL" ] || { echo "::error::missing $TMPL"; exit 1; }

# Canonical doc filenames the `api_reference` tool serves (docFiles values).
CANON="$(grep -oE '"(sketch|full|examples)": "[^"]+"' "$HANDLER" | sed -E 's/.*: "([^"]+)"/\1/')"
if [ -z "$CANON" ]; then
  echo "::error::could not extract docFiles from $HANDLER (renamed?). Update this script."
  exit 1
fi

# Doc paths the scaffolded AGENTS.md points agents at (after the docs-root placeholder).
REFS="$(grep -oE '\{\{METAPHOR_AI_DOCS_PATH\}\}/[A-Za-z0-9._/-]+' "$TMPL" \
  | sed -E 's#\{\{METAPHOR_AI_DOCS_PATH\}\}/##' || true)"

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if ! printf '%s\n' "$CANON" | grep -qxF -- "$ref"; then
    echo "::error::template references doc '$ref' that api_reference does not serve."
    echo "          $TMPL may only reference: $(echo "$CANON" | tr '\n' ' ')"
    echo "          (renamed/removed a doc? update the template, SketchToolHandler.docFiles,"
    echo "           and CONTRACT.md together.)"
    fail=1
  fi
done <<EOF
$REFS
EOF

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Template freshness check FAILED."
  exit 1
fi

echo "Template freshness check passed (template doc refs are a subset of api_reference docs)."
