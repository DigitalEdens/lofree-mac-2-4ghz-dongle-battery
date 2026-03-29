#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist-dev"
APP_PLIST="$ROOT_DIR/App/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
DMG_PATH="$DIST_DIR/LofreeDongleBatteryDev-${SHORT_VERSION}-compat-debug.dmg"

/bin/zsh "$ROOT_DIR/scripts/build_dev_app.sh"
/bin/zsh "$ROOT_DIR/scripts/create_dev_dmg.sh"
/bin/zsh "$ROOT_DIR/scripts/generate_dev_appcast.sh"

echo "Compatibility debug release ready:"
echo "$DMG_PATH"
