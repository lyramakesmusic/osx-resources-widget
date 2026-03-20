#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="SystemWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling..."
swiftc -O \
    -framework SwiftUI \
    -framework AppKit \
    -o "$APP/Contents/MacOS/SystemWidget" \
    SystemWidget.swift

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SystemWidget</string>
    <key>CFBundleIdentifier</key>
    <string>com.lyra.systemwidget</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>SystemWidget</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Built $APP"
echo "Run: open ~/Projects/system-widget/SystemWidget.app"
