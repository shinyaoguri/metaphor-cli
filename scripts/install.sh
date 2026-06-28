#!/usr/bin/env bash
set -euo pipefail

OWNER="shinyaoguri"
REPO="metaphor-cli"
PRODUCT="metaphor"
PREFIX="${PREFIX:-"$HOME/.local"}"
# Optional: install from a local tarball instead of downloading (used by CI to
# smoke-test the freshly built archive end-to-end). Skips download + checksum.
ARCHIVE_OVERRIDE="${ARCHIVE:-}"

usage() {
  cat <<'USAGE'
Install metaphor-cli from the latest GitHub Release.

Usage:
  curl -fsSL https://raw.githubusercontent.com/shinyaoguri/metaphor-cli/main/scripts/install.sh | bash

Options:
  PREFIX=/usr/local bash scripts/install.sh

USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: metaphor-cli currently supports macOS only." >&2
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ASSET="metaphor-cli_macos_arm64.tar.gz" ;;
  *)
    echo "error: no metaphor-cli release asset is available for architecture: $ARCH" >&2
    exit 1
    ;;
esac

BINDIR="$PREFIX/bin"
LIBEXECDIR="$PREFIX/libexec/metaphor"
SHAREDIR="$PREFIX/share/metaphor"
BASE_URL="https://github.com/$OWNER/$REPO/releases/latest/download"
ARCHIVE_URL="$BASE_URL/$ASSET"
CHECKSUMS_URL="$BASE_URL/checksums.txt"

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

if [[ -n "$ARCHIVE_OVERRIDE" ]]; then
  echo "Using local archive $ARCHIVE_OVERRIDE"
  cp "$ARCHIVE_OVERRIDE" "$TMPDIR/$ASSET"
else
  echo "Downloading $ASSET..."
  curl -fsSL "$ARCHIVE_URL" -o "$TMPDIR/$ASSET"
  curl -fsSL "$CHECKSUMS_URL" -o "$TMPDIR/checksums.txt"

  EXPECTED="$(awk -v asset="$ASSET" '$0 ~ asset { print $1; exit }' "$TMPDIR/checksums.txt")"
  if [[ -z "$EXPECTED" ]]; then
    echo "error: checksum for $ASSET was not found." >&2
    exit 1
  fi

  ACTUAL="$(shasum -a 256 "$TMPDIR/$ASSET" | awk '{ print $1 }')"
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "error: checksum mismatch for $ASSET." >&2
    echo "expected: $EXPECTED" >&2
    echo "actual:   $ACTUAL" >&2
    exit 1
  fi
fi

tar -xzf "$TMPDIR/$ASSET" -C "$TMPDIR"

if [[ ! -f "$TMPDIR/$PRODUCT" ]]; then
  echo "error: archive did not contain $PRODUCT binary." >&2
  exit 1
fi

if [[ ! -d "$TMPDIR/Syphon.framework" ]]; then
  echo "error: archive did not contain Syphon.framework." >&2
  echo "       The $PRODUCT binary links Syphon and cannot launch without it." >&2
  exit 1
fi

# The binary loads Syphon.framework from @loader_path (its own directory), so the
# framework must sit beside the *real* binary. Install both into a private libexec
# dir and expose the executable through a bin symlink — dyld resolves the symlink
# before computing @loader_path, so the framework is found in libexec, $BINDIR
# stays uncluttered, and no install_name_tool/codesign toolchain is required.
mkdir -p "$BINDIR" "$LIBEXECDIR" "$SHAREDIR"
install -m 755 "$TMPDIR/$PRODUCT" "$LIBEXECDIR/$PRODUCT"
rm -rf "$LIBEXECDIR/Syphon.framework"
cp -R "$TMPDIR/Syphon.framework" "$LIBEXECDIR/Syphon.framework"
rm -f "$BINDIR/$PRODUCT"
ln -s "../libexec/metaphor/$PRODUCT" "$BINDIR/$PRODUCT"

if [[ -d "$TMPDIR/templates" ]]; then
  rm -rf "$SHAREDIR/templates"
  cp -R "$TMPDIR/templates" "$SHAREDIR/templates"
fi

# Fail loudly now if the bundled framework can't be resolved, instead of leaving
# the user with a binary that aborts on first use.
"$BINDIR/$PRODUCT" version >/dev/null

echo "Installed $PRODUCT to $BINDIR/$PRODUCT -> $LIBEXECDIR/$PRODUCT"
echo "Installed Syphon.framework to $LIBEXECDIR/Syphon.framework"
echo "Installed templates to $SHAREDIR/templates"

case ":$PATH:" in
  *":$BINDIR:"*)
    echo "Run: metaphor --help"
    ;;
  *)
    echo ""
    echo "$BINDIR is not currently on PATH."
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$BINDIR:\$PATH\""
    ;;
esac
