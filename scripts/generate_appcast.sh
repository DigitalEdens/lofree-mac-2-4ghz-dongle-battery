#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PLIST="$ROOT_DIR/App/Info.plist"
APPCAST_PATH="$ROOT_DIR/docs/appcast.xml"
RELEASE_NOTES_DIR="$ROOT_DIR/docs/release-notes"
SPARKLE_BIN="$ROOT_DIR/Vendor/bin/sign_update"
REPO_SLUG="DigitalEdens/lofree-mac-2-4ghz-dongle-battery"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-tag>" >&2
  exit 1
fi

RELEASE_TAG="$1"

"$ROOT_DIR/scripts/setup_sparkle.sh"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
DMG_NAME="LofreeDongleBattery-${SHORT_VERSION}.dmg"
DMG_PATH="$ROOT_DIR/dist/$DMG_NAME"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Missing DMG: $DMG_PATH" >&2
  exit 1
fi

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PLIST")"
PUB_DATE="$(LC_ALL=en_US.UTF-8 date -Ru)"
DMG_LENGTH="$(stat -f%z "$DMG_PATH")"
DMG_SIGNATURE="$("$SPARKLE_BIN" -p "$DMG_PATH" | tr -d '\n')"
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}/${DMG_NAME}"
PROJECT_LINK="https://github.com/${REPO_SLUG}"
VERSION_HISTORY_URL="https://github.com/${REPO_SLUG}/blob/main/docs/release-notes/${SHORT_VERSION}.md"

mkdir -p "$RELEASE_NOTES_DIR"

if [[ ! -f "$RELEASE_NOTES_DIR/${SHORT_VERSION}.md" ]]; then
  cat > "$RELEASE_NOTES_DIR/${SHORT_VERSION}.md" <<EOF
# Lofree Dongle Battery ${SHORT_VERSION}

- Initial public release with live 2.4 GHz battery monitoring for the tested Flow Lite100 setup.
- Menu bar battery percentage, charging state, and voltage details.
- Input Monitoring explanation and GitHub-hosted update support.
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

cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Lofree 2.4 GHz Dongle Battery Updates</title>
    <description>Official Sparkle updates for the Lofree 2.4 GHz Dongle Battery app.</description>
    <language>en</language>
    <link>${PROJECT_LINK}</link>
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

echo "Updated: $APPCAST_PATH"
