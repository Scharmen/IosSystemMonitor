#!/bin/bash
# Builds SystemInfo in Release mode and packages it as a DMG and a ZIP in ./dist.
#
# The app is signed "ad hoc" (no Apple Developer ID), so it runs on any Mac but macOS
# will ask for confirmation the first time it's opened. See README.md → Installation.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(xcodebuild -project SystemInfo.xcodeproj -target SystemInfo -configuration Release -showBuildSettings 2>/dev/null \
    | awk '/ MARKETING_VERSION / { print $3 }')
echo "Building SystemInfo ${VERSION}..."

rm -rf build dist
xcodebuild \
    -project SystemInfo.xcodeproj \
    -scheme SystemInfo \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    build | tail -n 3

APP="build/Build/Products/Release/SystemInfo.app"
mkdir -p dist/dmg

# DMG with a shortcut to /Applications for drag-and-drop installation and a custom volume icon.
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
cp scripts/assets/SystemInfo.icns dist/dmg/.VolumeIcon.icns
hdiutil create -quiet -volname "SystemInfo $VERSION" -srcfolder dist/dmg -ov -format UDRW dist/rw.dmg
MOUNT=$(hdiutil attach -nobrowse dist/rw.dmg | awk -F'\t' '/\/Volumes\// { print $NF }')
SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet dist/rw.dmg -format UDZO -o "dist/SystemInfo-$VERSION.dmg"
rm -rf dist/dmg dist/rw.dmg
# Give the DMG file itself the app icon too.
sips -i scripts/assets/icon-1024.png >/dev/null
DeRez -only icns scripts/assets/icon-1024.png > dist/icon.rsrc
Rez -append dist/icon.rsrc -o "dist/SystemInfo-$VERSION.dmg"
SetFile -a C "dist/SystemInfo-$VERSION.dmg"
rm dist/icon.rsrc

# ZIP as an alternative download.
ditto -c -k --keepParent "$APP" "dist/SystemInfo-$VERSION.zip"

echo "Done:"
ls -lh dist
