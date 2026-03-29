#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist-dev"
APP_NAME="LofreeDongleBatteryDev.app"
APP_DIR="$DIST_DIR/$APP_NAME"
APP_INFO="$APP_DIR/Contents/Info.plist"
MENU_BINARY="$APP_DIR/Contents/MacOS/LofreeDongleBattery"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
HELPER_APP_NAME="Lofree Dongle Battery Access.app"
HELPER_APP_DIR="$APP_DIR/Contents/Helpers/$HELPER_APP_NAME"
HELPER_INFO="$HELPER_APP_DIR/Contents/Info.plist"
HELPER_BINARY="$HELPER_APP_DIR/Contents/MacOS/LofreeDongleBatteryAccess"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_FILE="$APP_DIR/Contents/Resources/AppIcon.icns"
HELPER_ICON_FILE="$HELPER_APP_DIR/Contents/Resources/AppIcon.icns"
SPARKLE_DIR="$ROOT_DIR/Vendor"
SPARKLE_FRAMEWORK_SRC="$SPARKLE_DIR/Sparkle.framework"
SPARKLE_FRAMEWORK_DST="$FRAMEWORKS_DIR/Sparkle.framework"
discover_sign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    return
  fi

  local developer_id
  developer_id="$(security find-identity -v -p codesigning 2>/dev/null | sed -E -n 's/.*"(Developer ID Application:.*)"/\1/p' | head -n 1)"
  if [[ -n "$developer_id" ]]; then
    printf '%s\n' "$developer_id"
    return
  fi

  local apple_development
  apple_development="$(security find-identity -v -p codesigning 2>/dev/null | sed -E -n 's/.*"(Apple Development:.*)"/\1/p' | head -n 1)"
  if [[ -n "$apple_development" ]]; then
    printf '%s\n' "$apple_development"
    return
  fi

  printf '%s\n' "-"
}

SIGN_IDENTITY="$(discover_sign_identity)"
DEV_FEED_URL="$(python3 - <<'PY' "$ROOT_DIR/docs/dev-appcast.xml"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"

"$ROOT_DIR/scripts/setup_sparkle.sh"

rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources" \
  "$FRAMEWORKS_DIR" \
  "$HELPER_APP_DIR/Contents/MacOS" \
  "$HELPER_APP_DIR/Contents/Resources"

cp "$ROOT_DIR/App/Info.plist" "$APP_INFO"
cp "$ROOT_DIR/App/HelperInfo.plist" "$HELPER_INFO"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.digitaledens.lofreedonglebattery.dev" "$APP_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleName LofreeDongleBatteryDev" "$APP_INFO"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $DEV_FEED_URL" "$APP_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.digitaledens.lofreedonglebattery.dev.access" "$HELPER_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Lofree Dongle Battery Access Dev" "$HELPER_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")" "$HELPER_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")" "$HELPER_INFO"

rm -rf "$ICONSET_DIR"

ditto "$SPARKLE_FRAMEWORK_SRC" "$SPARKLE_FRAMEWORK_DST"

swift "$ROOT_DIR/App/Assets/render_app_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
cp "$ICON_FILE" "$HELPER_ICON_FILE"
rm -rf "$ICONSET_DIR"

swiftc -framework AppKit \
  -framework CoreBluetooth \
  -F "$SPARKLE_DIR" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$ROOT_DIR/Sources/LofreeDongleBatteryMenu/main.swift" \
  -o "$MENU_BINARY"

swiftc \
  "$ROOT_DIR/Sources/LofreeDongleBattery/main.swift" \
  -o "$HELPER_BINARY"

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
sign_bundle "$HELPER_APP_DIR"
sign_bundle "$APP_DIR"

echo "Built dev app: $APP_DIR"
