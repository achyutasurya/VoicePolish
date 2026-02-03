#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="VoicePolish"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# 1. Build release
swift build -c release

# 2. Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# 4. Copy Info.plist
cp "$PROJECT_DIR/VoicePolish/Info.plist" "$APP_BUNDLE/Contents/"

# 5. Code sign with Apple Development certificate (stable identity for TCC permissions)
codesign --force --deep --sign "Apple Development: achyutasuryatej@icloud.com (4B3CUD9DRZ)" "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
