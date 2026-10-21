#!/bin/zsh
# Builds Vitals.app (menu bar app + bundled agent) with the Command Line Tools; no Xcode needed.
set -euo pipefail
cd "${0:A:h}"
APP=build/Vitals.app
# One version for everything: the agent's (Sources/Core/Model.swift), which the app checks on each Mac.
VERSION=$(sed -n 's/^let vitalsVersion = "\(.*\)"$/\1/p' Sources/Core/Model.swift)
FLAGS=(-O -target arm64-apple-macos14 -swift-version 5)

rm -rf build/gen && mkdir -p build/gen
# The pages' scripts, checked before they are embedded: a syntax error would leave a dashboard half
# drawn with nothing to say why. Needs Node; without it the check is skipped.
if command -v node >/dev/null; then
  for page in Sources/Web/index.html Sources/Web/screen.html; do
    awk '/<script[^>]*>/{f=1; next} /<\/script>/{f=0} f' $page > build/gen/check.mjs
    node --check build/gen/check.mjs || { echo "syntax error in $page's script"; exit 1; }
  done
fi
# The phone dashboard ships inside the agent: the page, and a Home Screen icon cut from the app icon
# (full-bleed, since iOS rounds the corners itself).
iconutil -c iconset -o build/gen/AppIcon.iconset Resources/AppIcon.icns
sips -c 680 680 build/gen/AppIcon.iconset/icon_512x512@2x.png --out build/gen/icon-crop.png >/dev/null
sips -z 180 180 build/gen/icon-crop.png --out build/gen/icon.png >/dev/null
cat > build/gen/WebAssets.swift <<SWIFT
import Foundation
enum WebAssets {
    static let page = Data(base64Encoded: "$(base64 -i Sources/Web/index.html)")!
    static let icon = Data(base64Encoded: "$(base64 -i build/gen/icon.png)")!
    static let screen = Data(base64Encoded: "$(base64 -i Sources/Web/screen.html)")!
    static let novnc = Data(base64Encoded: "$(base64 -i Sources/Web/vendor/novnc-1.7.0.js)")!
    static let novncGz = Data(base64Encoded: "$(gzip -9 -n -c Sources/Web/vendor/novnc-1.7.0.js | base64)")!
}
SWIFT
swiftc $FLAGS -o build/vitals-agent Sources/Core/*.swift Sources/Agent/*.swift build/gen/WebAssets.swift
swiftc $FLAGS -o build/Vitals Sources/Core/Model.swift Sources/Core/Fans.swift Sources/Core/SMC.swift Sources/App/*.swift

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp build/Vitals $APP/Contents/MacOS/Vitals
cp build/vitals-agent $APP/Contents/Resources/vitals-agent
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vitals</string>
  <key>CFBundleDisplayName</key><string>Vitals</string>
  <key>CFBundleIdentifier</key><string>app.vitals.menubar</string>
  <key>CFBundleExecutable</key><string>Vitals</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Vitals opens Terminal so you can type your password once to enable fan control on your Mac mini.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP/Contents/Resources/vitals-agent
codesign --force --sign - $APP
echo "built $APP $VERSION ($(du -sh $APP | cut -f1))"
