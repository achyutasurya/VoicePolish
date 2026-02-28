#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoicePolish"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ICON_SOURCE="$PROJECT_DIR/VoicePolish/AppIcon.icns"
SIGNING_IDENTITY='Apple Development: achyutasuryatej@icloud.com (4B3CUD9DRZ)'

echo "Building $APP_NAME..."

# 1. Build release
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

# 6. Copy SwiftPM resource bundles if present
find "$BUILD_DIR" -maxdepth 1 -type d -name "*.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# 7. Sign app bundle. Use configured Apple Development cert when available,
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
