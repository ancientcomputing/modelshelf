#!/bin/zsh
# Builds a Developer ID signed, notarized and stapled DMG for a GitHub release:
#   build/release/ModelShelf-<version>.dmg  (+ .sha256)
#
#   VERSION=1.0.0 packaging/release.sh
#
# Env:
#   VERSION         release version (default 1.0.0)
#   SIGN_IDENTITY   Developer ID Application identity (default: ThisBrainAI LLC)
#   NOTARY_PROFILE  notarytool keychain profile, created with
#                   `xcrun notarytool store-credentials <name> ...` (default: locallmlab-notary)
#   NOTARIZE        set to 0 to stop after signing (default 1)
set -euo pipefail
cd "${0:A:h}/.."

export VERSION="${VERSION:-1.0.0}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: ThisBrainAI LLC (MP7PDLDJ96)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-locallmlab-notary}"
NOTARIZE="${NOTARIZE:-1}"

APP="build/ModelShelf.app"
OUT="build/release"
DMG="$OUT/ModelShelf-$VERSION.dmg"

security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" || {
  echo "error: signing identity not found: $SIGN_IDENTITY" >&2; exit 1; }

# Submits a file, waits, and fails with Apple's log unless it was accepted.
notarize() {
  local file="$1" result id sub_status
  echo "Notarizing $file ..."
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  id="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  sub_status="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  echo "  submission $id: $sub_status"
  if [[ "$sub_status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi
}

# 1. Signed app.
./build-app.sh
rm -rf "$OUT"
mkdir -p "$OUT"

# 2. Notarize the app itself and staple it, so a copy dragged out of the DMG passes Gatekeeper offline.
if [[ "$NOTARIZE" == "1" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/ModelShelf-app.zip"
  notarize "$OUT/ModelShelf-app.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/ModelShelf-app.zip"
fi

# 3. DMG with an Applications shortcut, signed, notarized and stapled.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Model Shelf.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Model Shelf $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs APFS "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [[ "$NOTARIZE" == "1" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess --type execute -vv "$APP"
fi

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo
echo "Release artifacts:"
ls -lh "$OUT"
