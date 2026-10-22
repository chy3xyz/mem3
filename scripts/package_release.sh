#!/usr/bin/env bash
# Cross-compile mem3 and pack one archive per Homebrew target.
#
# Usage: bash scripts/package_release.sh [output-dir]
#
# Archives (binary named mem3 at the archive root):
#   aarch64-macos.zip
#   x86_64-macos.zip
#   aarch64-linux-musl.tar.xz
#   x86_64-linux-musl.tar.xz
#   SHA256SUMS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/zig-out/releases}"
WORK="$OUT/work"

rm -rf "$OUT"
mkdir -p "$WORK"

pack() {
  local target="$1"
  local archive="$2"
  local prefix="$WORK/$target"
  echo "building $target"
  zig build -Doptimize=ReleaseFast -Dtarget="$target" --prefix "$prefix"
  local bin="$prefix/bin/mem3"
  [ -s "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  case "$archive" in
    *.zip)
      # zip stores paths. Run it from the bin dir so the entry is "mem3".
      (cd "$prefix/bin" && zip -q -X "$OUT/$archive" mem3)
      ;;
    *.tar.xz)
      tar -cJf "$OUT/$archive" -C "$prefix/bin" mem3
      ;;
    *)
      echo "unknown archive $archive" >&2
      exit 1
      ;;
  esac
}

pack aarch64-macos aarch64-macos.zip
pack x86_64-macos x86_64-macos.zip
pack aarch64-linux-musl aarch64-linux-musl.tar.xz
pack x86_64-linux-musl x86_64-linux-musl.tar.xz

rm -rf "$WORK"
(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum *.zip *.tar.xz > SHA256SUMS
  else
    shasum -a 256 *.zip *.tar.xz > SHA256SUMS
  fi
)

echo "archives in $OUT"
cat "$OUT/SHA256SUMS"
