#!/bin/zsh
# Builds BitMatch.app next to this script.
#   ./build.sh                        build ./BitMatch.app
#   APP=dist/BitMatch.app ./build.sh  build somewhere else
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/BitMatch/Support.swift)"
APP="${APP:-BitMatch.app}"

swift build -c release
BINARY="$(swift build -c release --show-bin-path)/BitMatch"

rm -rf "$APP"; mkdir -p "$(dirname "$APP")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BitMatch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BitMatch</string>
    <key>CFBundleDisplayName</key><string>BitMatch</string>
    <key>CFBundleIdentifier</key><string>io.github.qkdeoddl12.BitMatch</string>
    <key>CFBundleExecutable</key><string>BitMatch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
