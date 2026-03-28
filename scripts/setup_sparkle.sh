#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"
SPARKLE_VERSION="2.9.0"
ARCHIVE_NAME="Sparkle-${SPARKLE_VERSION}.tar.xz"
ARCHIVE_PATH="$VENDOR_DIR/$ARCHIVE_NAME"
SPARKLE_FRAMEWORK_PATH="$VENDOR_DIR/Sparkle.framework"
SPARKLE_BIN_PATH="$VENDOR_DIR/bin"

if [[ -d "$SPARKLE_FRAMEWORK_PATH" && -d "$SPARKLE_BIN_PATH" ]]; then
  exit 0
fi

mkdir -p "$VENDOR_DIR"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl -L -o "$ARCHIVE_PATH" "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${ARCHIVE_NAME}"
fi

rm -rf \
  "$VENDOR_DIR/Sparkle.framework" \
  "$VENDOR_DIR/Sparkle Test App.app" \
  "$VENDOR_DIR/Symbols" \
  "$VENDOR_DIR/bin" \
  "$VENDOR_DIR/CHANGELOG" \
  "$VENDOR_DIR/INSTALL" \
  "$VENDOR_DIR/LICENSE" \
  "$VENDOR_DIR/SampleAppcast.xml"

tar -xf "$ARCHIVE_PATH" -C "$VENDOR_DIR"

if [[ ! -d "$SPARKLE_FRAMEWORK_PATH" || ! -d "$SPARKLE_BIN_PATH" ]]; then
  echo "Sparkle was not extracted correctly." >&2
  exit 1
fi
