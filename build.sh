#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoicePolish"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ICON_SOURCE="$PROJECT_DIR/VoicePolish/AppIcon.icns"
SIGNING_IDENTITY='Apple Development: achyutasuryatej@icloud.com (4B3CUD9DRZ)'

echo "Building $APP_NAME..."

# 1. Build release.
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

# 2. Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# 4. Copy Info.plist
cp "$PROJECT_DIR/VoicePolish/Info.plist" "$APP_BUNDLE/Contents/"

# 5. Copy app icon used by CFBundleIconFile
cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/"

# 6. Copy SwiftPM resource bundles into Contents/Resources/ (standard macOS
# layout). The binary patch below makes the runtime accessor find them here.
find "$BUILD_DIR" -maxdepth 1 -type d -name "*.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# 6a. Patch the binary's hardcoded `buildPath` constants so they point inside
# the installed .app instead of the developer's .build directory.
#
# SwiftPM's generated Bundle.module accessor (in DerivedSources/) builds two
# candidate paths for each resource bundle:
#     mainPath  = Bundle.main.bundleURL.appendingPathComponent("<name>.bundle").path
#     buildPath = "<absolute path to .build/.../release/<name>.bundle>"
# `mainPath` resolves to /MyApp.app/<name>.bundle, which is NOT where macOS
# puts resource bundles (they belong in Contents/Resources/), so it always
# returns nil for a properly-laid-out .app. The accessor then falls back to
# `buildPath` — an absolute path baked in at compile time that points into
# the developer's working tree. As long as `.build/` still has the bundle, the
# fallback works. The moment .build/ is cleaned, the project is moved, or the
# app runs on any other machine, Bundle.module fatalErrors and the app crashes
# the instant any KeyboardShortcuts.Recorder is built in SettingsView — which
# manifests as "menubar icon click silently quits the app."
#
# Fix: rewrite each hardcoded buildPath string in place to point at
# /Applications/VoicePolish.app/Contents/Resources/<name>.bundle, padding with
# trailing slashes so the byte length matches the original (so the length
# immediate that Swift's String literal carries stays valid; Bundle(path:)
# treats trailing slashes as equivalent).
python3 - "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$PROJECT_DIR" <<'PY'
import sys, pathlib
binary_path = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
old_prefix = f"{project_dir}/.build/arm64-apple-macosx/release/"
new_prefix = "/Applications/VoicePolish.app/Contents/Resources/"
data = bytearray(binary_path.read_bytes())
for bundle in ("KeyboardShortcuts_KeyboardShortcuts.bundle", "VoicePolish_VoicePolish.bundle"):
    old_path = (old_prefix + bundle).encode()
    new_base = (new_prefix + bundle).encode()
    if len(new_base) > len(old_path):
        print(f"  SKIP {bundle}: new path longer ({len(new_base)}) than old ({len(old_path)})")
        continue
    padded = new_base + b"/" * (len(old_path) - len(new_base))
    if old_path not in data:
        print(f"  SKIP {bundle}: original buildPath not found in binary")
        continue
    count = data.count(old_path)
    data = data.replace(old_path, padded)
    print(f"  Patched {bundle} buildPath ({count} occurrence{'s' if count != 1 else ''})")
binary_path.write_bytes(bytes(data))
PY

# 7. Sign app bundle. The binary patch above invalidates the original signature,
# so we must re-sign. Use configured Apple Development cert when available,
# otherwise fall back to ad-hoc signing so local installs still work.
if security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
    echo "Signing identity not found, using ad-hoc signing"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo ""
echo "Build complete: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
