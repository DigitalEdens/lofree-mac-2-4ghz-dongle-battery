#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PLIST="$ROOT_DIR/App/Info.plist"
APPCAST_PATH="$ROOT_DIR/docs/dev-appcast.xml"
RELEASE_NOTES_DIR="$ROOT_DIR/docs/dev-release-notes"
SPARKLE_BIN="$ROOT_DIR/Vendor/bin/sign_update"

"$ROOT_DIR/scripts/setup_sparkle.sh"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST")"
DMG_SUFFIX="${DEV_RELEASE_SUFFIX:--compat-debug}"
DMG_NAME="LofreeDongleBatteryDev-${SHORT_VERSION}${DMG_SUFFIX}.dmg"
DMG_PATH="$ROOT_DIR/dist-dev/$DMG_NAME"
DOWNLOAD_URL="$(python3 - <<'PY' "$DMG_PATH"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"
VERSION_HISTORY_URL="$(python3 - <<'PY' "$ROOT_DIR/docs/dev-release-notes/${SHORT_VERSION}.md"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
)"
PUB_DATE="$(LC_ALL=en_US.UTF-8 date -Ru)"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Missing dev DMG: $DMG_PATH" >&2
  echo "Run ./scripts/create_dev_dmg.sh first." >&2
  exit 1
fi

mkdir -p "$RELEASE_NOTES_DIR"

if [[ ! -f "$RELEASE_NOTES_DIR/${SHORT_VERSION}.md" ]]; then
  cat > "$RELEASE_NOTES_DIR/${SHORT_VERSION}.md" <<EOF
# Lofree Dongle Battery Dev ${SHORT_VERSION}

- Compatibility debug build for testing unsupported 2.4 GHz Lofree models before changes are approved for the public app.
EOF
fi

RELEASE_NOTES_HTML="$(python3 - "$RELEASE_NOTES_DIR/${SHORT_VERSION}.md" <<'PY'
import html
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

title = ""
bullets = []
paragraphs = []

for raw in lines:
    line = raw.strip()
    if not line:
        continue
    if line.startswith("# "):
        title = html.escape(line[2:])
    elif line.startswith("- "):
        bullets.append(html.escape(line[2:]))
    else:
        paragraphs.append(html.escape(line))

parts = []
if title:
    parts.append(f"<h2>{title}</h2>")
for paragraph in paragraphs:
    parts.append(f"<p>{paragraph}</p>")
if bullets:
    parts.append("<ul>")
    for bullet in bullets:
        parts.append(f"<li>{bullet}</li>")
    parts.append("</ul>")

print("".join(parts))
PY
)"

DMG_LENGTH="$(stat -f%z "$DMG_PATH")"
DMG_SIGNATURE="$("$SPARKLE_BIN" -p "$DMG_PATH" | tr -d '\n')"

cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Lofree 2.4 GHz Dongle Battery Dev Updates</title>
    <description>Local Sparkle updates for the dev sandbox build.</description>
    <language>en</language>
    <link>${VERSION_HISTORY_URL}</link>
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <link>${VERSION_HISTORY_URL}</link>
      <description><![CDATA[${RELEASE_NOTES_HTML}]]></description>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure url="${DOWNLOAD_URL}" length="${DMG_LENGTH}" type="application/octet-stream" sparkle:edSignature="${DMG_SIGNATURE}" />
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF

echo "Updated dev appcast: $APPCAST_PATH"
