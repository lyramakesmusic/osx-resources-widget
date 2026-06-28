#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ResourceDisplayWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling..."
swiftc -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework IOKit \
    -o "$APP/Contents/MacOS/ResourceDisplayWidget" \
    SystemWidget.swift

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ResourceDisplayWidget</string>
    <key>CFBundleIdentifier</key>
    <string>com.lyra.resourcedisplaywidget</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ResourceDisplayWidget</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Built $APP"
echo "Run: open ~/Projects/system-widget/ResourceDisplayWidget.app"
