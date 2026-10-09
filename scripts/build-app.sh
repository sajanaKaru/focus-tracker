#!/bin/bash
# Builds a release binary and wraps it in build/FocusTracker.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FocusTracker"

APP="build/FocusTracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FocusTracker"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"