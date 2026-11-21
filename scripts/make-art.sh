#!/bin/zsh
# Regenerates Resources/AppIcon.icns and docs/screenshot.png from the SwiftUI views.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=".build/release/BitMatch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BIN" --render icon "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" Resources docs
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
sips -z 256 256 "$WORK/icon.png" --out docs/icon.png >/dev/null

# The README is in English, so render the screenshot in English too.
"$BIN" -AppleLanguages "(en)" --render popover docs/screenshot.png
echo "Wrote Resources/AppIcon.icns, docs/icon.png, docs/screenshot.png"
