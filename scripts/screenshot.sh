#!/bin/zsh
# Renders usage and settings images from the real menu windows with sample data.
# The usage image includes only StayVibe's captured menu bar item, with its empty background extended.
# The Mac must be unlocked; failures leave both checked-in screenshots unchanged.
set -euo pipefail
cd "${0:A:h}/.."
swift build --disable-keychain
BIN=$(swift build --disable-keychain --show-bin-path)
TMP=$(mktemp -d)
APP=$TMP/Snapshot.app
cleanup() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
    /usr/bin/defaults delete io.github.dvdsanyi.stayvibe.snapshot >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$APP"/Contents/{MacOS,Frameworks,Resources}
cp "$BIN/StayVibe" "$APP/Contents/MacOS/"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 27.0 --output-partial-info-plist /dev/null >/dev/null
plutil -create xml1 "$APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string io.github.dvdsanyi.stayvibe.snapshot "$APP/Contents/Info.plist"
plutil -insert CFBundleExecutable -string StayVibe "$APP/Contents/Info.plist"
plutil -insert CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
for language in zh en; do
    for page in screenshot settings; do
        ARGS=(--snapshot "$language")
        if [[ "$page" == settings ]]; then ARGS+=(--snapshot-settings); fi
        # Pre-open output descriptors so the isolated GUI app needs no folder-access prompt.
        if ! open -n -W --stdout "$TMP/$page-$language.png" --stderr "$TMP/$page-$language.log" "$APP" \
            --args $ARGS; then
            cat "$TMP/$page-$language.log" >&2
            exit 1
        fi
        if [[ ! -s "$TMP/$page-$language.png" ]] || ! /usr/bin/grep -q '^snapshot: wrote ' "$TMP/$page-$language.log"; then
            cat "$TMP/$page-$language.log" >&2
            echo "could not capture the real menu bar window; unlock the Mac and retry" >&2
            exit 1
        fi
        sips -g pixelWidth -g pixelHeight "$TMP/$page-$language.png" >/dev/null
        /usr/bin/grep '^snapshot:' "$TMP/$page-$language.log"
    done
done
for page in screenshot settings; do
    for language in zh en; do cp "$TMP/$page-$language.png" "docs/$page-$language.png"; done
done
echo "wrote usage and settings images in docs/"
