#!/bin/zsh
# Writes build/release/appcast.xml, Sparkle's feed of the release scripts/release.sh built: one item for its DMG,
# signed with the Sparkle EdDSA key in this Mac's keychain (Sparkle's generate_keys), or in the file
# SPARKLE_KEY_FILE names, with the release notes' body as the update's description.
#
#   scripts/appcast.sh <notes.md>
#
# The app reads the feed from the newest GitHub release (SPARKLE_FEED_URL), so a release publishes the DMG and
# this file only.
set -euo pipefail

cd "${0:A:h}/.."
notes=${1:?usage: appcast.sh <notes.md>}
out=build/release
source "$out/release.env"
repository=https://github.com/0xnoahzhu/Tidemark
dmg="$out/Tidemark-$VERSION.dmg"

sign_update=build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
key=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then key=(--ed-key-file "$SPARKLE_KEY_FILE"); fi
signature=$("$sign_update" "${key[@]}" "$dmg")   # sparkle:edSignature="…" length="…"
if [[ "$signature" != *edSignature=* ]]; then
    echo "sign_update gave no signature: $signature" >&2
    exit 1
fi

# The notes' body (everything after the `# Title` line) as HTML: `## ` headings, `- ` lists, paragraphs.
description=$(sed '1{/^# /d;}' "$notes" | awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    /^## / { if (list) { print "</ul>"; list = 0 } print "<h3>" esc(substr($0, 4)) "</h3>"; next }
    /^- /  { if (!list) { print "<ul>"; list = 1 } print "<li>" esc(substr($0, 3)) "</li>"; next }
    /^$/   { if (list) { print "</ul>"; list = 0 } next }
           { if (list) { print "</ul>"; list = 0 } print "<p>" esc($0) "</p>" }
    END    { if (list) print "</ul>" }')

cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tidemark</title>
    <link>$repository</link>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repository/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$description
      ]]></description>
      <enclosure url="$repository/releases/download/v$VERSION/Tidemark-$VERSION.dmg" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$out/appcast.xml"
echo "Wrote $out/appcast.xml"
