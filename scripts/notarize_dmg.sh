#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PLIST="$ROOT_DIR/App/Info.plist"
DMG_PATH="${1:-$DIST_DIR/LofreeDongleBattery.dmg}"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
VERSIONED_DMG_PATH="$DIST_DIR/LofreeDongleBattery-${SHORT_VERSION}.dmg"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-lofree-notary}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found at: $DMG_PATH" >&2
  echo "Run ./scripts/create_dmg.sh first." >&2
  exit 1
fi

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"

cp "$DMG_PATH" "$VERSIONED_DMG_PATH"

echo "Notarized and stapled: $DMG_PATH"
echo "Updated versioned copy: $VERSIONED_DMG_PATH"
