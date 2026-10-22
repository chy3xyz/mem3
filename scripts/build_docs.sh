#!/usr/bin/env bash
# Build the mem3 manual with zdoc (https://github.com/chy3xyz/zdoc).
#
# Usage:
#   bash scripts/build_docs.sh [output-dir] [url-prefix]
#
# Defaults: output-dir=site/public, url-prefix=/mem3/ (GitHub Pages project site).
# Pass / as the second argument when the site is served at a domain root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/site/public}"
URL_PREFIX="${2:-/mem3/}"
ZDOC_VERSION="v0.16.2"
TOOLS="$ROOT/.tools"

case "$(uname -sm)" in
  "Darwin arm64")  ZDOC_ASSET="aarch64-macos.zip" ;;
  "Darwin x86_64") ZDOC_ASSET="x86_64-macos.zip" ;;
  "Linux x86_64")  ZDOC_ASSET="x86_64-linux-musl.tar.xz" ;;
  "Linux aarch64") ZDOC_ASSET="aarch64-linux-musl.tar.xz" ;;
  *) echo "unsupported platform: $(uname -sm)" >&2; exit 1 ;;
esac

mkdir -p "$TOOLS"
ZDOC_BIN="$TOOLS/zdoc"
ver=""
if [ -x "$ZDOC_BIN" ]; then
  ver="$("$ZDOC_BIN" version 2>&1 || true)"
fi
if [[ "$ver" != *"${ZDOC_VERSION#v}"* ]]; then
  echo "downloading zdoc $ZDOC_VERSION ($ZDOC_ASSET)..."
  rm -f "$TOOLS/zdoc"
  curl -fsSL "https://github.com/chy3xyz/zdoc/releases/download/$ZDOC_VERSION/$ZDOC_ASSET" -o "$TOOLS/$ZDOC_ASSET"
  curl -fsSL "https://github.com/chy3xyz/zdoc/releases/download/$ZDOC_VERSION/SHA256SUMS" -o "$TOOLS/SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$TOOLS" && grep " $ZDOC_ASSET\$" SHA256SUMS | sha256sum -c -)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$TOOLS" && grep " $ZDOC_ASSET\$" SHA256SUMS | shasum -a 256 -c -)
  else
    echo "no sha256sum or shasum; skipped checksum" >&2
  fi
  case "$ZDOC_ASSET" in
    *.zip) unzip -o -q "$TOOLS/$ZDOC_ASSET" -d "$TOOLS" ;;
    *.tar.xz) tar -xJf "$TOOLS/$ZDOC_ASSET" -C "$TOOLS" ;;
  esac
  chmod +x "$ZDOC_BIN"
fi

rm -rf "$OUT"
"$ZDOC_BIN" docs "$ROOT/site/docs" --output "$OUT" --title "mem3" --url-prefix "$URL_PREFIX" --force

echo "docs site written to $OUT (url prefix: $URL_PREFIX)"
