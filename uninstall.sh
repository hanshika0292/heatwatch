#!/bin/bash
# Stops HeatWatch and removes the app and its login item. Your logs and reports are kept.
set -euo pipefail

LABEL=local.heatwatch
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x HeatWatch 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/HeatWatch.app"

echo "HeatWatch removed."
echo "Your data is still in: $HOME/Library/Application Support/HeatWatch (delete it yourself if you want)."
