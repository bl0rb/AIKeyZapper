#!/bin/bash
# Builds dist/KeyZapper-<version>.pkg for Intune ("macOS app (PKG)"); installs KeyZapper.app to /Applications.
#   VERSION             app/package version (default 0.1.0); Intune detects updates via CFBundleShortVersionString
#   SIGN_IDENTITY       passed to build-app.sh ("Developer ID Application: …")
#   INSTALLER_IDENTITY  optional "Developer ID Installer: …" to sign the package
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.1.0}"
scripts/build-app.sh

ROOT="$(mktemp -d)"
mkdir -p "$ROOT/Applications"
ditto --noextattr --noqtn dist/KeyZapper.app "$ROOT/Applications/KeyZapper.app"
COMPONENTS="$(mktemp -d)/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS" >/dev/null
# Always install to /Applications, even if another copy with the same bundle ID exists elsewhere.
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENTS"

SIGN=()
[ -n "${INSTALLER_IDENTITY:-}" ] && SIGN=(--sign "$INSTALLER_IDENTITY")
PKG="dist/KeyZapper-$VERSION.pkg"
pkgbuild --root "$ROOT" --component-plist "$COMPONENTS" --install-location / \
  --identifier io.github.bl0rb.keyzapper.pkg --version "$VERSION" ${SIGN[@]+"${SIGN[@]}"} "$PKG"
echo "Built $PKG"
