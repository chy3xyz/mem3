#!/usr/bin/env bash
# Build the mem3 documentation site with zdoc (https://github.com/chy3xyz/zdoc).
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
STAGE="$ROOT/.zdoc-build"

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

rm -rf "$STAGE"
mkdir -p "$STAGE"
# Authored pages, including section indexes that the copies below must not delete.
rsync -a --exclude '.DS_Store' "$ROOT/site/docs/" "$STAGE/"

# Repository docs. The manuscript and the alpha release notes stay out:
# the manuscript is Chinese, and the release-note performance table is not
# what the current bench prints. library/index.md explains both.
rsync -a \
  --exclude '属性数学_出版版.md' \
  --exclude 'releases/' \
  --exclude '.DS_Store' \
  "$ROOT/docs/" "$STAGE/library/"

python3 - "$STAGE/library/roadmap.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    "](deploy/logrotate.conf)",
    "](https://github.com/chy3xyz/mem3/blob/main/docs/deploy/logrotate.conf)",
)
open(path, "w", encoding="utf-8").write(text)
PY

python3 - "$ROOT/.specify/memory/constitution.md" "$STAGE/library/constitution.md" <<'PY'
import re, sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
text = re.sub(r"<!--.*?-->\n?", "", text, flags=re.S)
open(dst, "w", encoding="utf-8").write(text)
PY

rsync -a --exclude '.DS_Store' \
  "$ROOT/specs/001-trisource-everos-mvp/" "$STAGE/specification/"

cp "$ROOT/dev.md" "$STAGE/notes/engineering-blueprint.md"
python3 - "$ROOT/ghw_memory_system.agent.final.md" "$STAGE/notes/ghw-paper.md" <<'PY'
import re, sys
src, dst = sys.argv[1:]
text = open(src, encoding="utf-8").read()
# The paper links three figures that were never committed.
text = re.sub(
    r"!\[([^\]]*)\]\((fig_[^)]+)\)",
    r"> Figure not in the repository: \1 (`\2`).",
    text,
)
open(dst, "w", encoding="utf-8").write(text)
PY

rm -rf "$OUT"
"$ZDOC_BIN" docs "$STAGE" --output "$OUT" --title "mem3" --url-prefix "$URL_PREFIX" --force

echo "docs site written to $OUT (url prefix: $URL_PREFIX)"
