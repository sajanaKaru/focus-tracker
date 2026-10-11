#!/bin/bash
# Builds a release binary and wraps it in build/FocusTracker.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; source .env; set +a; fi

# Firebase Web API key (Project settings → General); the release app locks without it.
: "${FIREBASE_API_KEY:?Set FIREBASE_API_KEY before building}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FocusTracker"

APP="build/FocusTracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FocusTracker"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :FirebaseAPIKey $FIREBASE_API_KEY" "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"