#!/bin/zsh
# Packages a release into dist/: signed app → DMG → Sparkle signature → appcast.xml.
# Runs in GitHub Actions on every v* tag, and works the same on a Mac.
# Env: VERSION (e.g. 1.2.0), SPARKLE_PRIVATE_KEY (see setup-signing.sh).
set -euo pipefail
cd "${0:A:h}/.."
: ${VERSION:?set VERSION, e.g. VERSION=1.0.0}
: ${SPARKLE_PRIVATE_KEY:?set SPARKLE_PRIVATE_KEY; updates must be signed}

VERSION=$VERSION scripts/build.sh
APP=build/StayVibe.app
BUILD=$(plutil -extract CFBundleVersion raw $APP/Contents/Info.plist)

rm -rf dist
mkdir -p dist/dmg
cp -R $APP dist/dmg/
ln -s /Applications dist/dmg/Applications
DMG=dist/StayVibe-$VERSION.dmg
diskutil image create from --volumeName StayVibe dist/dmg $DMG >/dev/null
rm -rf dist/dmg

SIGN_UPDATE=$(find .build/artifacts -name sign_update -type f | head -1)
SIGNATURE=$(print -r -- $SPARKLE_PRIVATE_KEY | $SIGN_UPDATE --ed-key-file - $DMG)  # sparkle:edSignature="…" length="…"
REPO=https://github.com/dvdsanyi/StayVibe
cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>StayVibe</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$REPO/releases/download/v$VERSION/StayVibe-$VERSION.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
echo "dist: $(ls dist | tr '\n' ' ')"
