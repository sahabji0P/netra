#!/bin/zsh
# Build and (re)start a development app bundle in the menu bar.
set -e
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$PWD/dist/Netra.app"

scripts/build-app.sh "$VERSION"

# Only one Netra menu extra should own the status item. This also replaces an
# older /Applications installation that would otherwise remain visible while
# the newly-built executable exits or launches invisibly behind it.
pkill -x Netra 2>/dev/null || true
sleep 0.5
open -n "$APP"
sleep 1

if ! pgrep -f "$APP/Contents/MacOS/Netra" >/dev/null; then
  echo "Netra failed to stay running from $APP" >&2
  exit 1
fi

echo "Netra $VERSION is running from $APP — look for the eye in your menu bar."
