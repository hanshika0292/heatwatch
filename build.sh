#!/bin/bash
# Builds build/HeatWatch.app with the Xcode command-line tools (no Xcode project needed).
# The app is universal: one copy runs natively on Apple silicon and Intel Macs.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HeatWatch.app
OBJ=build/obj
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos12.0" \
    -framework AppKit -framework IOKit \
    Sources/*.swift -o "$OBJ/HeatWatch-$ARCH"
done
lipo -create "$OBJ"/HeatWatch-* -output "$APP/Contents/MacOS/HeatWatch"
rm -rf "$OBJ"

cp Info.plist "$APP/Contents/"
cp Resources/report.html "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP (Apple silicon + Intel)"
