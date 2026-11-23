#!/bin/zsh
# Builds ModelShelf.app into ./build. Usage: ./build-app.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "${0:A:h}"

swift build -c release --product ModelShelf
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/ModelShelf"
APP="build/ModelShelf.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/ModelShelf"
# LocalLM SDK frameworks (dynamic) and any SwiftPM resource bundles.
for fw in "$BINDIR"/*.framework(N); do cp -R "$fw" "$APP/Contents/Frameworks/"; done
for b in "$BINDIR"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Model Shelf</string>
  <key>CFBundleDisplayName</key><string>Model Shelf</string>
  <key>CFBundleIdentifier</key><string>local.modelshelf</string>
  <key>CFBundleExecutable</key><string>ModelShelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Model Shelf keeps your model library on an external drive.</string>
</dict>
</plist>
PLIST

for fw in "$APP"/Contents/Frameworks/*.framework(N); do codesign --force --sign - "$fw" >/dev/null; done
codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/ModelShelf.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/ModelShelf.app"
fi
