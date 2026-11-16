#!/bin/zsh
# Regenerates packaging/AppIcon.icns from scripts/make-icon.swift.
# Usage: scripts/make-icon.sh
set -e
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

/usr/bin/swift scripts/make-icon.swift "$WORK"
iconutil --convert icns --output packaging/AppIcon.icns "$WORK/AppIcon.iconset"
cp "$WORK/netra-app-icon-1024.png" packaging/brand/netra-app-icon-1024.png

echo "Wrote packaging/AppIcon.icns and packaging/brand/netra-app-icon-1024.png"
