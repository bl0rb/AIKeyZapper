#!/bin/bash
# Builds dist/ProjectAISwitch.app with the helper in Contents/Helpers.
#   SIGN_IDENTITY  codesign identity (default "-" = ad hoc; use "Developer ID Application: …" for release)
#   BUNDLE_ID      bundle identifier (default com.company.projectaiswitch)
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-com.company.projectaiswitch}"
IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-0.1.0}"

swift build -c release --product ProjectAISwitch
swift build -c release --product aiswitch-key-helper
BIN="$(swift build -c release --show-bin-path)"

APP=dist/ProjectAISwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/ProjectAISwitch" "$APP/Contents/MacOS/"
cp "$BIN/aiswitch-key-helper" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>ProjectAISwitch</string>
  <key>CFBundleExecutable</key><string>ProjectAISwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

OPTS=(--force --timestamp=none)
[ "$IDENTITY" != "-" ] && OPTS=(--force --timestamp --options runtime)
# Sign the helper first with its own stable identifier: keychain ACLs trust this identity.
codesign "${OPTS[@]}" -s "$IDENTITY" -i "$BUNDLE_ID.key-helper" "$APP/Contents/Helpers/aiswitch-key-helper"
codesign "${OPTS[@]}" -s "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP (identity: $IDENTITY)"
