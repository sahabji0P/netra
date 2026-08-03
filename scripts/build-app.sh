#!/bin/zsh
# Assembles dist/Netra.app from the SwiftPM release build.
# Usage: scripts/build-app.sh [version]   (default 0.0.0-dev)
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
APP="dist/Netra.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Netra "$APP/Contents/MacOS/Netra"
cp ccusage-bin "$APP/Contents/Resources/ccusage-bin"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp packaging/ccusage-LICENSE "$APP/Contents/Resources/ccusage-LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Netra</string>
    <key>CFBundleDisplayName</key><string>Netra</string>
    <key>CFBundleIdentifier</key><string>in.airaai.netra</string>
    <key>CFBundleExecutable</key><string>Netra</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Shashwat Jain. ccusage engine © its contributors (MIT).</string>
</dict>
</plist>
PLIST

# Sign the nested helper first, then the bundle (required nesting order).
IDENTITY="${NETRA_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP/Contents/Resources/ccusage-bin"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

echo "Built $APP (version $VERSION, signed: ${IDENTITY:-ad-hoc})"
