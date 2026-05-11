#!/usr/bin/env bash
# Generates AppIcon.icns from the square 1024px source image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${ROOT}/AppIcon-1024.png"
OUT="${ROOT}/AppIcon.icns"
SET="${ROOT}/AppIcon.iconset"
rm -rf "$SET" "$OUT"
mkdir -p "$SET"

mk() { sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null; }

mk 16   icon_16x16.png
mk 32   icon_16x16@2x.png
mk 32   icon_32x32.png
mk 64   icon_32x32@2x.png
mk 128  icon_128x128.png
mk 256  icon_128x128@2x.png
mk 256  icon_256x256.png
mk 512  icon_256x256@2x.png
mk 512  icon_512x512.png
sips -z 1024 1024 "$SRC" --out "$SET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "$OUT"
