#!/bin/bash
# Builds HeatWatch, installs it to ~/Applications and starts it now and at every login.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications/HeatWatch.app"
LABEL=local.heatwatch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Stop any running copy before replacing it.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x HeatWatch 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/HeatWatch.app "$DEST"

"$DEST/Contents/MacOS/HeatWatch" --enable-login-item
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "HeatWatch is running. Look for the temperature in your menu bar."
echo "Data and reports: $HOME/Library/Application Support/HeatWatch"
