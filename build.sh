#!/bin/bash
# Builds "Public Equity Screener.app" into ./build. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Public Equity Screener.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MarketScreener "$APP/Contents/MacOS/MarketScreener"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Public Equity Screener</string>
    <key>CFBundleDisplayName</key><string>Public Equity Screener</string>
    <key>CFBundleIdentifier</key><string>com.tillknuesting.equityscreener</string>
    <key>CFBundleExecutable</key><string>MarketScreener</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
