#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building AntigravityUsageBar..."

rm -rf build
mkdir -p build

APP_NAME="AntigravityUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp Info.plist "$APP_PATH/Contents/"

if [ ! -f "AntigravityUsageBar.icns" ]; then
    echo "Creating app icon..."
    chmod +x make_app_icon.sh
    ./make_app_icon.sh
fi

if [ -f "AntigravityUsageBar.icns" ]; then
    cp AntigravityUsageBar.icns "$APP_PATH/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AntigravityUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AntigravityUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile universal binary (arm64 + x86_64)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/AntigravityUsageBar_arm64" \
    AntigravityUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -target arm64-apple-macos12.0

swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/AntigravityUsageBar_x86_64" \
    AntigravityUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -target x86_64-apple-macos12.0

lipo -create -output "$APP_PATH/Contents/MacOS/AntigravityUsageBar" \
    "$APP_PATH/Contents/MacOS/AntigravityUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/AntigravityUsageBar_x86_64"

rm "$APP_PATH/Contents/MacOS/AntigravityUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/AntigravityUsageBar_x86_64"

echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"
chmod 755 "$APP_PATH/Contents/MacOS/AntigravityUsageBar"

xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null || true
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null || true
dot_clean "$APP_PATH" 2>/dev/null || true

# Ad-hoc sign so macOS runs locally without Developer ID issues
codesign --force --deep --sign - "$APP_PATH"

echo "✅ Build successful: $APP_PATH"

if [ "${1:-}" != "--no-open" ]; then
    echo "Launching AntigravityUsageBar..."
    open "$APP_PATH"
fi
