#!/bin/zsh
# Builds build/ModelShelf.app (Apple silicon).
#
#   ./build-app.sh             ad-hoc signed: runs on this Mac only
#   ./build-app.sh --install   also copies it to /Applications
#
# Env:
#   SIGN_IDENTITY  codesigning identity. Default "-" (ad hoc). With a real identity the app and the
#                  bundled LocalLM SDK frameworks are signed with the hardened runtime and a secure
#                  timestamp, ready for notarization (see packaging/release.sh).
#   VERSION        CFBundleShortVersionString (default 1.0.0)
#   BUILD_NUMBER   CFBundleVersion (default: the git commit count)
#   SANDBOX        1 to sign with packaging/ModelShelf.entitlements (App Sandbox), as the Mac App
#                  Store requires. The app then asks for the cache and library folders on first run.
#   PROVISIONING_PROFILE  a Mac App Store profile to embed (packaging/release-mas.sh sets this). Its
#                  application and team identifiers are added to the entitlements.
set -euo pipefail
cd "${0:A:h}"

IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ENTITLEMENTS=()
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then SANDBOX=1; fi
if [[ "${SANDBOX:-0}" == "1" ]]; then
  mkdir -p build
  cp packaging/ModelShelf.entitlements build/ModelShelf.entitlements
  ENTITLEMENTS=(--entitlements build/ModelShelf.entitlements)
fi
if [[ "$IDENTITY" == "-" ]]; then
  SIGN=(--force --sign -)
else
  SIGN=(--force --options runtime --timestamp --sign "$IDENTITY")
fi

swift build -c release --arch arm64 --product ModelShelf
BINDIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/ModelShelf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/ModelShelf" "$APP/Contents/MacOS/ModelShelf"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# LocalLM SDK frameworks (dynamic, found through @executable_path/../Frameworks) and any SwiftPM
# resource bundles. The published xcframework zips carry AppleDouble files and xattrs that break
# signing, so strip them.
for fw in "$BINDIR"/*.framework(N); do cp -R "$fw" "$APP/Contents/Frameworks/"; done
for b in "$BINDIR"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# App icon: compile the asset catalog (PNGs from packaging/generate_app_icon.py) into Assets.car,
# which System Settings reads, and AppIcon.icns, which Finder and the Dock read.
ICON_TMP="build/icon"
rm -rf "$ICON_TMP" && mkdir -p "$ICON_TMP"
xcrun actool --compile "$ICON_TMP" --platform macosx --minimum-deployment-target 27.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICON_TMP/partial.plist" \
  --errors --warnings --output-format human-readable-text \
  packaging/Resources/Assets.xcassets >/dev/null
cp "$ICON_TMP/Assets.car" "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/"

find "$APP" -name '._*' -delete
xattr -cr "$APP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Model Shelf</string>
  <key>CFBundleDisplayName</key><string>Model Shelf</string>
  <key>CFBundleIdentifier</key><string>ai.thisbrain.modelshelf</string>
  <key>CFBundleExecutable</key><string>ModelShelf</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Apache License 2.0</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSRemovableVolumesUsageDescription</key><string>Model Shelf keeps your model library on an external drive.</string>
</dict>
</plist>
PLIST

if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  # A manual codesign only embeds what's in the entitlements file, and App Store Connect rejects a
  # signature without the application identifier the profile carries.
  PROFILE_PLIST="$(security cms -D -i "$PROVISIONING_PROFILE")"
  APP_ID="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - <<<"$PROFILE_PLIST")"
  TEAM_ID="$(plutil -extract 'Entitlements.com\.apple\.developer\.team-identifier' raw -o - - <<<"$PROFILE_PLIST")"
  [[ "$APP_ID" == *.ai.thisbrain.modelshelf ]] || { echo "error: profile is for $APP_ID, not ai.thisbrain.modelshelf" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" build/ModelShelf.entitlements
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" build/ModelShelf.entitlements
fi

# Sign inside-out: each framework's nested bundles, its binary, the framework; then the app.
for fw in "$APP"/Contents/Frameworks/*.framework(N); do
  find "$fw" -depth -type d -name '*.bundle' -print0 | while IFS= read -r -d '' b; do codesign "${SIGN[@]}" "$b"; done
  codesign "${SIGN[@]}" "$fw/Versions/Current/${${fw:t}%.framework}"
  codesign "${SIGN[@]}" "$fw"
done
codesign "${SIGN[@]}" "${ENTITLEMENTS[@]}" "$APP/Contents/MacOS/ModelShelf"
codesign "${SIGN[@]}" "${ENTITLEMENTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $PWD/$APP ($VERSION, build $BUILD_NUMBER, signed by: $IDENTITY${ENTITLEMENTS:+, sandboxed})"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/ModelShelf.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/ModelShelf.app"
fi
