#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="LikeWindows"
PROJECT="LikeWindows.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
STAGING_DIR="$ROOT_DIR/build/dmg-staging"
EXPORT_DIR="$ROOT_DIR/build/export"
APP_NAME="LikeWindows"
VOLUME_NAME="如窗"

echo "==> Building ${SCHEME} (Release)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
DMG_NAME="${APP_NAME}-${VERSION}(${BUILD_NUMBER}).dmg"
DMG_PATH="$EXPORT_DIR/$DMG_NAME"

echo "==> Preparing DMG staging (${VERSION}(${BUILD_NUMBER}))..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$EXPORT_DIR"
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Done."
echo "    App:  $APP_PATH"
echo "    DMG:  $DMG_PATH"
echo "    Version: ${VERSION} (${BUILD_NUMBER})"
