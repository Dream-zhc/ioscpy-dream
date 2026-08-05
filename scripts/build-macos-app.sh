#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/macos}"
VERSION="0.3.0-dream.4"
APP_NAME="ioscpy dream"
APP="$OUT/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"

swift build --package-path "$ROOT/macos" -c release --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT/macos" -c release --arch arm64 --show-bin-path)"
install -m 755 "$BIN_DIR/ioscpy-dream" "$APP/Contents/MacOS/ioscpy-dream"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SOURCE="$ROOT/host/assets/AppIcon.png"
for spec in \
  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Ad-hoc only: no Developer ID, provisioning profile, timestamp, or notarization.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

ARCHIVE="$OUT/ioscpy-dream-$VERSION-macos-arm64.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$OUT/SHA256SUMS-macos"
printf '{"version":"%s","platform":"macos","architecture":"arm64","minimum_macos":"26.0","formal_signature":false}\n' \
  "$VERSION" > "$OUT/build-manifest-macos.json"

echo "$APP"
echo "$ARCHIVE"
