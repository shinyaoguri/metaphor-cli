#!/usr/bin/env bash
#
# Wire-schema conformance check (metaphor <-> metaphor-cli).
#
# Validates the canonical example payloads in contract/examples/ against the
# JSON Schemas in contract/*.schema.json. This is the machine-readable half of
# the Probe file contract (CONTRACT.md point 4): grep (check-contract.sh) guards
# non-JSON tokens, this guards JSON structure/value-range/enum/schemaVersion.
#
# The Swift tests keep contract/examples/ honest against the real encoders;
# this script keeps contract/examples/ valid against the schemas. Transitively,
# the real producer output (and the cli's consumer output) conforms to schema.
#
# Requires `check-jsonschema` (pip install check-jsonschema). Swift has no good
# native JSON Schema validator, so we shell out (see design note section 5.1).
#
# This script is kept IDENTICAL in both repositories. If you edit it, copy the
# change to the other repo too.
#
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "::error::check-jsonschema not found. Install it: pip install check-jsonschema"
  exit 1
fi

fail=0

# validate <schema> <example...> — every example must conform to the schema.
validate() {
  schema="contract/$1"; shift
  if [ ! -f "$schema" ]; then
    echo "::error::contract schema missing: $schema"
    fail=1
    return
  fi
  for example in "$@"; do
    if [ ! -f "$example" ]; then
      echo "::error::contract example missing: $example"
      fail=1
      continue
    fi
    if ! check-jsonschema --schemafile "$schema" "$example"; then
      echo "::error::$example does not conform to $schema"
      echo "          This is part of the metaphor <-> metaphor-cli wire contract (see contract/README.md)."
      fail=1
    fi
  done
}

validate frame.schema.json    contract/examples/frame.json contract/examples/frame-minimal.json contract/examples/frame-failure.json
validate request.schema.json  contract/examples/request.json contract/examples/request-minimal.json
validate sequence.schema.json contract/examples/sequence.json

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Wire-schema check FAILED — see contract/README.md and CONTRACT.md."
  exit 1
fi

echo "Wire-schema check passed."
