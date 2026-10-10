#!/bin/bash
# Build a plain installer image with no Finder automation or reused artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then scripts/build-app.sh release; fi
APP="build/Clipline.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/Clipline.app"
ln -s /Applications "$WORK/stage/Applications"
cp LICENSE "$WORK/stage/LICENSE.txt"
cp NOTICE.md "$WORK/stage/NOTICE.txt"
cp docs/INSTALL.txt "$WORK/stage/INSTALL.txt"
hdiutil create -quiet -ov -srcfolder "$WORK/stage" -volname Clipline -format UDZO "build/Clipline-$VERSION-universal.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/Clipline-$VERSION-universal.zip"
(cd build && shasum -a 256 "Clipline-$VERSION-universal.dmg" "Clipline-$VERSION-universal.zip" > SHA256SUMS.txt)
echo "Built Clipline $VERSION DMG and ZIP"
