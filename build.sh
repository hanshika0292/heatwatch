#!/bin/bash
# Builds build/HeatWatch.app with the Xcode command-line tools (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HeatWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "$(uname -m)-apple-macos12.0" \
  -framework AppKit -framework IOKit \
  Sources/*.swift -o "$APP/Contents/MacOS/HeatWatch"

cp Info.plist "$APP/Contents/"
cp Resources/report.html "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
