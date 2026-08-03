#!/bin/zsh
# Build and (re)start Netra in the menu bar.
set -e
cd "$(dirname "$0")"
swift build
pkill -f '.build/debug/Netra' 2>/dev/null || true
sleep 0.5
nohup .build/debug/Netra > /tmp/netra-dev.log 2>&1 &
echo "Netra is running — look for the eye in your menu bar. Stop it with: pkill -f Netra"
