#!/bin/bash
# Build "Claude Usage.app" — a small floating desktop widget showing live
# Claude Code session (5-hour) and weekly usage limits.
# No Xcode project required; uses swiftc from the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage.app"
EXE="ClaudeUsage"
MIN_MACOS="13"
ARCH="$(uname -m)"

ICON_SRC="ClaudeUsage.png"
ICON_NAME="AppIcon"

echo "Building $APP for $ARCH-apple-macos$MIN_MACOS …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Optional app icon (Finder/Dock). Skipped silently if ClaudeUsage.png is absent.
if [ -f "$ICON_SRC" ]; then
    echo "Generating $ICON_NAME.icns from $ICON_SRC …"
    ICONSET="$(mktemp -d)/$ICON_NAME.iconset"
    mkdir -p "$ICONSET"
    SQUARE="$(mktemp -d)/icon_square.png"
    sips -s format png -z 1024 1024 "$ICON_SRC" --out "$SQUARE" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z $size $size             "$SQUARE" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
        sips -z $((size*2)) $((size*2)) "$SQUARE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$ICON_NAME.icns"
fi

swiftc -parse-as-library -swift-version 5 -O \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    Sources/ClaudeUsage.swift \
    -framework AppKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleExecutable</key>      <string>$EXE</string>
    <key>CFBundleIconFile</key>        <string>$ICON_NAME</string>
    <key>CFBundleIconName</key>        <string>$ICON_NAME</string>
    <key>CFBundleIdentifier</key>      <string>com.claudeusagewidget.mac</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper lets it launch on this machine.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app will still run locally)"

echo "Done → $(pwd)/$APP"
