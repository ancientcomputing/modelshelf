#!/bin/zsh
# Builds a Mac App Store package: build/release-mas/ModelShelf-<version>.pkg
#
#   VERSION=1.1.0 packaging/release-mas.sh
#
# Sandboxed, signed with Apple Distribution, provisioning profile embedded, packaged with
# productbuild and signed with the installer certificate. Upload the .pkg with Transporter or
# `xcrun altool`/App Store Connect. App Review replaces notarization for this path.
#
# One-time setup in the Apple Developer portal (team MP7PDLDJ96):
#   1. Identifiers: an App ID for ai.thisbrain.modelshelf.
#   2. Profiles: a "Mac App Store Connect" distribution profile for it, downloaded into
#      ~/Library/Developer/Xcode/UserData/Provisioning Profiles (or pass PROVISIONING_PROFILE).
#   3. App Store Connect: a macOS app record with that bundle id.
#
# Env:
#   VERSION                  CFBundleShortVersionString (default 1.0.2)
#   BUILD_NUMBER             CFBundleVersion; must increase with every upload (default: commit count)
#   APP_SIGN_IDENTITY        default: Apple Distribution: ThisBrainAI LLC (MP7PDLDJ96)
#   INSTALLER_SIGN_IDENTITY  default: 3rd Party Mac Developer Installer: ThisBrainAI LLC (MP7PDLDJ96)
#   PROVISIONING_PROFILE     default: found by bundle id in Xcode's profile folder
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID="ai.thisbrain.modelshelf"
export VERSION="${VERSION:-1.0.2}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Apple Distribution: ThisBrainAI LLC (MP7PDLDJ96)}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-3rd Party Mac Developer Installer: ThisBrainAI LLC (MP7PDLDJ96)}"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
OUT="build/release-mas"
PKG="$OUT/ModelShelf-$VERSION.pkg"

security find-identity -v -p codesigning | grep -qF "$APP_SIGN_IDENTITY" || {
  echo "error: app signing identity not found: $APP_SIGN_IDENTITY" >&2; exit 1; }
security find-identity -v | grep -qF "$INSTALLER_SIGN_IDENTITY" || {
  echo "error: installer signing identity not found: $INSTALLER_SIGN_IDENTITY" >&2; exit 1; }

if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
  for candidate in "$PROFILES_DIR"/*.provisionprofile(N); do
    app_id="$(security cms -D -i "$candidate" 2>/dev/null | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - 2>/dev/null || true)"
    if [[ "$app_id" == *".$BUNDLE_ID" ]]; then PROVISIONING_PROFILE="$candidate"; break; fi
  done
fi
if [[ -z "${PROVISIONING_PROFILE:-}" || ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "error: no Mac App Store provisioning profile for $BUNDLE_ID in $PROFILES_DIR." >&2
  echo "       Create one in the Apple Developer portal (see the top of this script) or set PROVISIONING_PROFILE." >&2
  exit 1
fi
echo "Using profile: $PROVISIONING_PROFILE"

SIGN_IDENTITY="$APP_SIGN_IDENTITY" PROVISIONING_PROFILE="$PROVISIONING_PROFILE" ./build-app.sh

rm -rf "$OUT" && mkdir -p "$OUT"
productbuild --component build/ModelShelf.app /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG"
codesign -d --entitlements - build/ModelShelf.app 2>/dev/null | grep -E "app-sandbox|application-identifier" || true
echo
echo "Mac App Store package: $PWD/$PKG"
