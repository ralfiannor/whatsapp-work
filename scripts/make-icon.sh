#!/bin/bash
# make-icon.sh — regenerate the WhatsAppWork app icon.
#
#   ./scripts/make-icon.sh [source-image.png]
#
# Default source: apps/macos/icon-source.png (the original artwork, kept in the
# repo). Produces WhatsAppWork/Resources/AppIcon.icns via icongen.swift
# (1024 master with macOS-grid margins) + sips (sizes) + iconutil (.icns).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/apps/macos/icon-source.png}"
OUT_ICNS="$ROOT/apps/macos/WhatsAppWork/Resources/AppIcon.icns"
MASTER="$(mktemp -d)/master.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

[ -f "$SRC" ] || { echo "make-icon: source not found: $SRC" >&2; exit 1; }

BIN="$(mktemp -d)/icongen"
swiftc -O "$ROOT/scripts/icongen.swift" -o "$BIN"
"$BIN" "$SRC" "$MASTER"

for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
# 512@2x is the 1024 master itself; no 1024@2x exists in an iconset.
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT_ICNS")"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "make-icon: wrote $OUT_ICNS"
