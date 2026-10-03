#!/bin/sh
set -eu
cd "$(dirname "$0")"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo 'Version must be three numbers, for example 0.1.0.' >&2
    exit 1
fi
swift build --build-system native -c release --product Lantern
BIN_PATH="$(swift build --build-system native -c release --show-bin-path)"
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
cp "$BIN_PATH/Lantern" "$APP/Contents/MacOS/Lantern"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.lantern.mac "$APP"
printf '\nBuilt %s\n' "$APP"
