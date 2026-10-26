#!/bin/zsh
# Builds a Release archive of Tidemark and packages it as build/release/Tidemark-<version>.dmg, with the installer
# window laid out by scripts/dmg (the app, a dashed arrow, the Applications link), next to its debug symbols
# (Tidemark-<version>.dSYM).
#
# Needs Xcode (DEVELOPER_DIR defaults to /Applications/Xcode.app) and uv, which runs dmgbuild. The app is ad-hoc
# signed: it opens on this Mac, but Gatekeeper blocks it elsewhere until it is opened with right-click › Open.
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

out=build/release
rm -rf "$out"
mkdir -p "$out"

echo "Archiving the Release build…"
xcodebuild archive -project Tidemark.xcodeproj -scheme Tidemark -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$out/Tidemark.xcarchive" \
    -derivedDataPath build/ReleaseDerivedData > "$out/archive.log"

app="$out/Tidemark.xcarchive/Products/Applications/Tidemark.app"
codesign --verify --deep --strict "$app"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
dmg="$out/Tidemark-$version.dmg"

echo "Packaging $dmg…"
uv run --quiet --no-project --with dmgbuild==1.6.7 dmgbuild \
    -s scripts/dmg/settings.py -D app="$app" -D background=scripts/dmg/background.tiff \
    "Tidemark $version" "$dmg"

hdiutil verify -quiet "$dmg"

# Keep only the DMG and the app's debug symbols: the archive's copy of the app would linger as one more Tidemark.app.
mv "$out/Tidemark.xcarchive/dSYMs/Tidemark.app.dSYM" "$out/Tidemark-$version.dSYM"
rm -rf "$out/Tidemark.xcarchive"
# The archive's build folder keeps a link to where the app was built before it moved into the archive.
find build/ReleaseDerivedData -name '*.app' -type l -delete

shasum -a 256 "$dmg"
