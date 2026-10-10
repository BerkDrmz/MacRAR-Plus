#!/bin/zsh
# A local, ad-hoc-signed package. Use release.sh for Developer ID signing/notarization.
set -e
cd "$(dirname "$0")"
APP="$PWD/build/MacRAR Plus.app"
[[ -d "$APP" ]] || ./build.sh
mkdir -p dist
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="$PWD/dist/MacRAR-Plus-$VERSION-arm64.zip"
DMG="$PWD/dist/MacRAR-Plus-$VERSION-arm64.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp README.tr.md "$STAGE/Beni Oku.md"
mkdir -p "$STAGE/docs/plus"
cp "docs/plus/$VERSION.tr.md" "$STAGE/docs/plus/"
for image in docs/plus/Workspace.png docs/plus/Compression.png; do
  if [[ -f "$image" ]]; then cp "$image" "$STAGE/docs/plus/"; fi
done
hdiutil create -volname 'MacRAR Plus' -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
echo "ZIP: $ZIP"
echo "DMG: $DMG"
