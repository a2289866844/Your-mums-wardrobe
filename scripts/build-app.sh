#!/bin/bash
# Build the wardrobe universal macOS app without changing installed apps.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/wardrobe.app"
VERSION="1.2.0"
# Keep the legacy bundle identity and storage paths across the product rename.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
build_arch() {
  local triple="$1-apple-macosx15.0"
  if ! swift build -c "$CONFIG" --triple "$triple" >&2; then
    if [ -n "${SDKROOT:-}" ]; then return 1; fi
    local fallback
    fallback="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$fallback" ]; then return 1; fi
    export SDKROOT="$fallback"
    swift build -c "$CONFIG" --triple "$triple" >&2
  fi
  cp "$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/Tendedero" "$WORK/wardrobe-$1"
  if [[ "$1" == "arm64" ]]; then
    ditto "$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/SQLCipher.framework" "$WORK/SQLCipher.framework"
  fi
}
build_arch arm64
build_arch x86_64
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
ditto "$WORK/SQLCipher.framework" "$APP/Contents/Frameworks/SQLCipher.framework"
lipo -create "$WORK/wardrobe-arm64" "$WORK/wardrobe-x86_64" -output "$APP/Contents/MacOS/wardrobe"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/wardrobe"
swift scripts/make-icon.swift "$WORK/icon.png"
ICONSET="$WORK/wardrobe.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/wardrobe.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp NOTICE.md "$APP/Contents/Resources/NOTICE.txt"
ditto ThirdPartyLicenses "$APP/Contents/Resources/ThirdPartyLicenses"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>wardrobe</string>
<key>CFBundleDisplayName</key><string>wardrobe</string>
<key>CFBundleIdentifier</key><string>io.github.a2289866844.clipline</string>
<key>CFBundleExecutable</key><string>wardrobe</string>
<key>CFBundleIconFile</key><string>wardrobe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>wardrobe watches your screenshot folder to display new captures.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Frameworks/SQLCipher.framework" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
