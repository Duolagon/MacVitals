#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/MacVitals.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/MacVitals "$APP/Contents/MacOS/MacVitals"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacVitals</string>
<key>CFBundleDisplayName</key><string>MacVitals</string>
<key>CFBundleIdentifier</key><string>local.macvitals.monitor</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleExecutable</key><string>MacVitals</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.macvitals.monitor</string><key>CFBundleURLSchemes</key><array><string>macvitals</string></array></dict></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
WIDGET="$APP/Contents/PlugIns/MacVitalsWidgets.appex"
mkdir -p "$WIDGET/Contents/MacOS"
cp Widgets/Info.plist "$WIDGET/Contents/Info.plist"
xcrun swiftc -O -parse-as-library -application-extension -module-name MacVitalsWidgets \
    -target "$(uname -m)-apple-macos14.0" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    Widgets/MacVitalsWidgets.swift Widgets/TelemetryWidgetView.swift Sources/MacVitals/WidgetSnapshot.swift Sources/MacVitals/MetricsFormat.swift \
    -o "$WIDGET/Contents/MacOS/MacVitalsWidgets"
codesign --force --sign - --entitlements Widgets/Widgets.entitlements "$WIDGET"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
print "已生成：$APP"
