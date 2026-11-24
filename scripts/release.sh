#!/bin/zsh
# Builds a signed Tidemark release into build/release:
#   Tidemark-<version>.dmg   the installer window (scripts/dmg: the app, a dashed arrow, the Applications link), which
#                            Sparkle also downloads to update the app
#   Tidemark-<version>.dSYM  the app's debug symbols (not published)
#   release.env              VERSION and BUILD, for scripts/appcast.sh
#
# The Release configuration signs with the Developer ID Application certificate of team 7939U549K7, and the archive is
# exported with scripts/ExportOptions.plist, which signs Sparkle's helpers too. The certificate comes from the
# keychains in the search list; TIDEMARK_KEYCHAIN names the one to look in first (the release workflow's temporary
# keychain).
#
# The DMG is notarized and stapled with an App Store Connect API key (TIDEMARK_NOTARY_KEY, the .p8 file's path, with
# TIDEMARK_NOTARY_KEY_ID and TIDEMARK_NOTARY_ISSUER) or a `xcrun notarytool store-credentials` keychain profile
# (TIDEMARK_NOTARY_PROFILE). With neither it is left unnotarized: a local dry run, which Gatekeeper blocks on other
# Macs.
#
# Needs Xcode (DEVELOPER_DIR defaults to /Applications/Xcode.app) and uv, which runs dmgbuild. No other copy of the app
# is left behind.
set -euo pipefail

cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
team=7939U549K7
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

out=build/release
rm -rf "$out"
mkdir -p "$out"

keychain=${TIDEMARK_KEYCHAIN:-}
identity=$(security find-identity -v -p codesigning ${keychain:+"$keychain"} | awk -v team="($team)" '/"Developer ID Application: / && index($0, team) { print $2; exit }')
if [[ -z "$identity" ]]; then
    echo "No Developer ID Application certificate of team $team in the keychain." >&2
    exit 1
fi
sign_flags="--timestamp${keychain:+ --keychain $keychain}"

echo "Archiving the Release build…"
xcodebuild archive -project Tidemark.xcodeproj -scheme Tidemark -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$out/Tidemark.xcarchive" \
    -derivedDataPath build/ReleaseDerivedData OTHER_CODE_SIGN_FLAGS="$sign_flags" > "$out/archive.log"

echo "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$out/Tidemark.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist scripts/ExportOptions.plist > "$out/export.log"

app="$out/export/Tidemark.app"
codesign --verify --deep --strict "$app"
# Read in full first: `grep -q` would stop reading early, and pipefail would count codesign's SIGPIPE as a failure.
signature=$(codesign -dvv "$app" 2>&1)
if [[ "$signature" != *"Authority=Developer ID Application: "*"($team)"* ]]; then
    echo "$app is not signed with Developer ID." >&2
    exit 1
fi
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
if [[ -z "$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist" 2>/dev/null)" ]]; then
    echo "warning: SPARKLE_PUBLIC_ED_KEY is empty: this build will not update itself." >&2
fi
dmg="$out/Tidemark-$version.dmg"

echo "Packaging $dmg…"
uv run --quiet --no-project --with dmgbuild==1.6.7 dmgbuild \
    -s scripts/dmg/settings.py -D app="$app" -D background=scripts/dmg/background.tiff \
    "Tidemark $version" "$dmg"
codesign --sign "$identity" ${=sign_flags} "$dmg"
hdiutil verify -quiet "$dmg"

notary=()
if [[ -n "${TIDEMARK_NOTARY_KEY:-}" ]]; then
    notary=(--key "$TIDEMARK_NOTARY_KEY" --key-id "${TIDEMARK_NOTARY_KEY_ID:?}" --issuer "${TIDEMARK_NOTARY_ISSUER:?}")
elif [[ -n "${TIDEMARK_NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$TIDEMARK_NOTARY_PROFILE")
fi
if (( ${#notary} )); then
    echo "Notarizing $dmg…"
    xcrun notarytool submit "$dmg" "${notary[@]}" --wait --output-format json > "$out/notary.json"
    notary_status=$(plutil -extract status raw "$out/notary.json")
    if [[ "$notary_status" != "Accepted" ]]; then
        echo "Notarization ended $notary_status:" >&2
        xcrun notarytool log "$(plutil -extract id raw "$out/notary.json")" "${notary[@]}" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
    echo "warning: no notarization credentials: the DMG is not notarized." >&2
fi

# Keep only the DMG and the app's debug symbols: the archive's and the export's copies of the app would linger as more
# Tidemark.app copies (and in Launch Services).
mv "$out/Tidemark.xcarchive/dSYMs/Tidemark.app.dSYM" "$out/Tidemark-$version.dSYM"
for copy in "$app" "$out/Tidemark.xcarchive/Products/Applications/Tidemark.app"; do
    "$lsregister" -u "$copy" 2>/dev/null || true
done
rm -rf "$out/Tidemark.xcarchive" "$out/export"
# The archive's build folder keeps a link to where the app was built before it moved into the archive.
find build/ReleaseDerivedData -name '*.app' -type l -delete

print "VERSION=$version\nBUILD=$build" > "$out/release.env"
shasum -a 256 "$dmg"
