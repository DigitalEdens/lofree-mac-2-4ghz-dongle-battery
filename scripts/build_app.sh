#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="LofreeDongleBattery.app"
APP_DIR="$DIST_DIR/$APP_NAME"
MENU_BINARY="$APP_DIR/Contents/MacOS/LofreeDongleBattery"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_FILE="$APP_DIR/Contents/Resources/AppIcon.icns"
SPARKLE_DIR="$ROOT_DIR/Vendor"
SPARKLE_FRAMEWORK_SRC="$SPARKLE_DIR/Sparkle.framework"
SPARKLE_FRAMEWORK_DST="$FRAMEWORKS_DIR/Sparkle.framework"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

"$ROOT_DIR/scripts/setup_sparkle.sh"

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources" \
  "$FRAMEWORKS_DIR"

cp "$ROOT_DIR/App/Info.plist" "$APP_DIR/Contents/Info.plist"

rm -rf "$ICONSET_DIR"

ditto "$SPARKLE_FRAMEWORK_SRC" "$SPARKLE_FRAMEWORK_DST"

swift "$ROOT_DIR/App/Assets/render_app_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
rm -rf "$ICONSET_DIR"

swiftc -framework AppKit \
  -framework CoreBluetooth \
  -F "$SPARKLE_DIR" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/LofreeDongleBatteryMenu/main.swift" \
  -o "$MENU_BINARY"

sign_bundle() {
  local path="$1"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$path"
  else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$path"
  fi
}

sign_bundle "$SPARKLE_FRAMEWORK_DST/Versions/B/XPCServices/Downloader.xpc"
sign_bundle "$SPARKLE_FRAMEWORK_DST/Versions/B/XPCServices/Installer.xpc"
sign_bundle "$SPARKLE_FRAMEWORK_DST/Versions/B/Updater.app"
sign_bundle "$SPARKLE_FRAMEWORK_DST/Versions/B/Autoupdate"
sign_bundle "$SPARKLE_FRAMEWORK_DST"
sign_bundle "$APP_DIR"

echo "Built: $APP_DIR"
