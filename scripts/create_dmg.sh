#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LofreeDongleBattery.app"
APP_DIR="$DIST_DIR/$APP_NAME"
DMG_NAME="LofreeDongleBattery.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"
APPLICATIONS_LINK="$STAGING_DIR/Applications"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at: $APP_DIR" >&2
  echo "Run ./scripts/build_app.sh first." >&2
  exit 1
fi

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$APPLICATIONS_LINK"

hdiutil create \
  -volname "Lofree Dongle Battery" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

rm -rf "$STAGING_DIR"

echo "Created: $DMG_PATH"
