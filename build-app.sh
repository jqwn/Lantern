#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build --build-system native -c release --product Lantern
APP="${1:-$PWD/dist/Lantern.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$PWD/.build/Lantern.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/Lantern.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" Resources/Lantern.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Lantern.icns"
cp .build/release/Lantern "$APP/Contents/MacOS/Lantern"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.lantern.mac "$APP"
printf '\nBuilt %s\n' "$APP"
