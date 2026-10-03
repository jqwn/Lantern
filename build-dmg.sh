#!/bin/sh
set -eu
cd "$(dirname "$0")"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo 'Usage: sh build-dmg.sh [MAJOR.MINOR.PATCH]' >&2
    exit 1
fi
mkdir -p .build dist
STAGING="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
sh build-app.sh "$STAGING/Lantern.app" "$VERSION"
codesign --verify --deep --strict "$STAGING/Lantern.app"
plutil -lint "$STAGING/Lantern.app/Contents/Info.plist"
ln -s /Applications "$STAGING/Applications"
cp Resources/Install.txt "$STAGING/Read Me.txt"
DMG="Lantern-$VERSION-$(uname -m).dmg"
hdiutil create -volname Lantern -srcfolder "$STAGING" -fs HFS+ -format UDZO "$PWD/dist/$DMG"
hdiutil verify "$PWD/dist/$DMG"
(cd dist && shasum -a 256 "$DMG" > "$DMG.sha256")
printf '\nBuilt %s/dist/%s (staging retained at %s)\n' "$PWD" "$DMG" "$STAGING"
