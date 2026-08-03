#!/bin/zsh
# Build and (re)start Netra in the menu bar.
set -e
cd "$(dirname "$0")"
swift build
# Stable signing identity so the Keychain "Always Allow" for the Claude
# credentials survives rebuilds (ad-hoc signatures change every build).
# Override with NETRA_SIGN_ID; falls back to the first available identity,
# then to ad-hoc so the script still works on machines without a certificate.
IDENTITY="${NETRA_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" .build/debug/Netra
pkill -f '.build/debug/Netra' 2>/dev/null || true
sleep 0.5
nohup .build/debug/Netra > /tmp/netra-dev.log 2>&1 &
echo "Netra is running — look for the eye in your menu bar. Stop it with: pkill -f Netra"
