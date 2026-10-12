#!/bin/bash
# Build a native fixture host. This does not launch it or change TCC/settings.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
APP="${1:-$ROOT/build/Clipline Verification.app}"
mkdir -p "$ROOT/build"
if [[ -e "$APP" ]]; then
  echo "Verification app already exists; retain it or move it before rebuilding." >&2
  exit 2
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNTIME="$(mktemp -d "$ROOT/build/verification-runtime.XXXXXX")"
SUITE="io.github.a2289866844.clipline.verification.$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$RUNTIME/Screenshots" "$RUNTIME/Clipboard"
cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let resource = Bundle.main.url(forResource: "Runtime", withExtension: "plist")!
    let configuration = NSDictionary(contentsOf: resource)!
    let runtime = URL(fileURLWithPath: configuration["folder"] as! String, isDirectory: true)
    let suite = configuration["suite"] as! String
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "soundOff")
    defaults.set(true, forKey: "welcomed")
    defaults.set(false, forKey: "clipboardEnabled")
    let line = Line(defaults: defaults, clipboardFolder: runtime.appendingPathComponent("Clipboard", isDirectory: true))
    let delegate = AppDelegate(line: line, screenshotFolder: runtime.appendingPathComponent("Screenshots", isDirectory: true), defaults: defaults)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
SWIFT
SOURCES=()
for source in Sources/Tendedero/*.swift; do
  [[ "$source" == "Sources/Tendedero/main.swift" ]] || SOURCES+=("$source")
done
xcrun swiftc -O -module-name Tendedero -target "$(uname -m)-apple-macosx14.0" \
  "${SOURCES[@]}" "$WORK/main.swift" -o "$WORK/CliplineVerification"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/CliplineVerification" "$APP/Contents/MacOS/CliplineVerification"
cp docs/clipline-icon.png "$APP/Contents/Resources/Clipline.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CliplineVerification</string>
<key>CFBundleIdentifier</key><string>io.github.a2289866844.clipline.verification</string>
<key>CFBundleName</key><string>Clipline Verification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.4</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Resources/Runtime.plist" "$RUNTIME" "$SUITE" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'folder': sys.argv[2], 'suite': sys.argv[3]}, file)
PY
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"
echo "Screenshot folder: $RUNTIME/Screenshots"
echo "Clipboard folder: $RUNTIME/Clipboard"
echo "Isolated shelf preferences: $SUITE"
echo "Not launched. No Desktop access or screenshot preference changes."
