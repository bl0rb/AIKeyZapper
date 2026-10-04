#!/bin/bash
# Builds dist/KeyZapper.app with the helper in Contents/Helpers.
#   SIGN_IDENTITY  codesign identity (default "-" = ad hoc; use "Developer ID Application: …" for release)
#   BUNDLE_ID      bundle identifier (default io.github.bl0rb.keyzapper)
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-io.github.bl0rb.keyzapper}"
IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-0.1.0}"

swift build -c release --product KeyZapper
swift build -c release --product keyzapper-helper
BIN="$(swift build -c release --show-bin-path)"

APP=dist/KeyZapper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/AppIcon.icns LICENSE "$APP/Contents/Resources/"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cp "$BIN/KeyZapper" "$APP/Contents/MacOS/"
cp "$BIN/keyzapper-helper" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>KeyZapper</string>
  <key>CFBundleExecutable</key><string>KeyZapper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 bl0rb · MIT License · github.com/bl0rb/ClaudeKeyZapper</string>
</dict></plist>
PLIST

OPTS=(--force --timestamp=none)
[ "$IDENTITY" != "-" ] && OPTS=(--force --timestamp --options runtime)
# Sign the helper first with its own stable identifier: keychain ACLs trust this identity.
codesign "${OPTS[@]}" -s "$IDENTITY" -i "$BUNDLE_ID.helper" "$APP/Contents/Helpers/keyzapper-helper"
codesign "${OPTS[@]}" -s "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP (identity: $IDENTITY)"
