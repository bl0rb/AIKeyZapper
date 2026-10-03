#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (AppKit SVG renderer).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
# macOS icon grid: 824 px tile centred on a transparent 1024 px canvas.
swift scripts/render-svg.swift Resources/AppIcon.svg "$TMP/1024.png" 1024 824
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/1024.png" "$TMP/preview.png" && echo "$TMP/preview.png"
