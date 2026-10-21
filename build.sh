#!/bin/zsh
# Builds Vitals.app (menu bar app + bundled agent) with the Command Line Tools; no Xcode needed.
set -euo pipefail
cd "${0:A:h}"
APP=build/Vitals.app
FLAGS=(-O -target arm64-apple-macos14 -swift-version 5)

rm -rf build/gen && mkdir -p build/gen
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
}
SWIFT
swiftc $FLAGS -o build/vitals-agent Sources/Core/*.swift Sources/Agent/main.swift Sources/Agent/Serve.swift build/gen/WebAssets.swift
swiftc $FLAGS -o build/Vitals Sources/Core/Model.swift Sources/Core/Fans.swift Sources/Core/SMC.swift Sources/App/*.swift

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp build/Vitals $APP/Contents/MacOS/Vitals
cp build/vitals-agent $APP/Contents/Resources/vitals-agent
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vitals</string>
  <key>CFBundleDisplayName</key><string>Vitals</string>
  <key>CFBundleIdentifier</key><string>app.vitals.menubar</string>
  <key>CFBundleExecutable</key><string>Vitals</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Vitals opens Terminal so you can type your password once to enable fan control on your Mac mini.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP/Contents/Resources/vitals-agent
codesign --force --sign - $APP
echo "built $APP ($(du -sh $APP | cut -f1))"
