#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="AntigravityUsageBar"
DMG_NAME="${APP_NAME}-Installer"

if [ ! -d "build/${APP_NAME}.app" ]; then
    ./build.sh --no-open
fi

TMP_DIR="dmg_temp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

cp -R "build/${APP_NAME}.app" "$TMP_DIR/"
xattr -cr "$TMP_DIR/${APP_NAME}.app"
ln -s /Applications "$TMP_DIR/Applications"

rm -f "${DMG_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "$TMP_DIR" -ov -format UDZO "${DMG_NAME}.dmg"
rm -rf "$TMP_DIR"

echo "✅ DMG created: app/${DMG_NAME}.dmg"
