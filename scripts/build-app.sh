#!/bin/zsh
# Assembles dist/Netra.app from the SwiftPM release build.
# Usage: scripts/build-app.sh [version]   (default: repository VERSION)
# The GPUI window (rust/) is nested as Contents/Helpers/Netra Dashboard.app.
# It is Netra's only dashboard, so the build fails without Rust (cargo).
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
APP="dist/Netra.app"

swift build -c release

# The GPUI window (rustup installs cargo outside PATH).
CARGO="$(command -v cargo || true)"
if [[ -z "$CARGO" && -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO" ]]; then
  echo "error: cargo not found. Netra's window is built with Rust: install it from https://rustup.rs" >&2
  exit 1
fi
(cd rust && "$CARGO" build --release -p netra-dashboard)
DASHBOARD_BIN="${CARGO_TARGET_DIR:-rust/target}/release/netra-dashboard"
if [[ ! -x "$DASHBOARD_BIN" ]]; then
  echo "error: $DASHBOARD_BIN is missing after the build" >&2
  exit 1
fi

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
    <key>CFBundleIdentifier</key><string>com.sahabji0P.netra</string>
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

DASHBOARD_APP="$APP/Contents/Helpers/Netra Dashboard.app"
if [[ -n "$DASHBOARD_BIN" ]]; then
  mkdir -p "$DASHBOARD_APP/Contents/MacOS" "$DASHBOARD_APP/Contents/Resources"
  cp "$DASHBOARD_BIN" "$DASHBOARD_APP/Contents/MacOS/netra-dashboard"
  cp packaging/AppIcon.icns "$DASHBOARD_APP/Contents/Resources/AppIcon.icns"
  cat > "$DASHBOARD_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Netra</string>
    <key>CFBundleDisplayName</key><string>Netra</string>
    <key>CFBundleIdentifier</key><string>com.sahabji0P.netra.dashboard</string>
    <key>CFBundleExecutable</key><string>netra-dashboard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
fi

# Sign the nested code first, then the bundle (required nesting order).
IDENTITY="${NETRA_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  # An ad-hoc signature is a new identity on every build, so macOS forgets
  # "Always Allow" for Claude Code's Keychain item and asks again.
  echo "warning: no signing identity found; signing ad-hoc (Keychain grants will not persist across builds)" >&2
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP/Contents/Resources/ccusage-bin"
if [[ -n "$DASHBOARD_BIN" ]]; then
  codesign --force --options runtime --sign "${IDENTITY:--}" "$DASHBOARD_APP"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

DASHBOARD_NOTE="not included"
[[ -n "$DASHBOARD_BIN" ]] && DASHBOARD_NOTE="included"
echo "Built $APP (version $VERSION, signed: ${IDENTITY:-ad-hoc}, GPUI dashboard: $DASHBOARD_NOTE)"
