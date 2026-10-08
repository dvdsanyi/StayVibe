#!/bin/zsh
# Renders docs/screenshot-{en,zh}.png from the real views with sample data. Runs the debug build
# as a throwaway app opened through LaunchServices: only then may its window become key, which
# switches and progress bars need to draw in their active colors.
set -euo pipefail
cd "${0:A:h}/.."
swift build --disable-keychain
BIN=$(swift build --disable-keychain --show-bin-path)
TMP=$(mktemp -d)
APP=$TMP/Snapshot.app
trap '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $APP; rm -rf $TMP' EXIT
mkdir -p $APP/Contents/{MacOS,Frameworks,Resources}
cp $BIN/StayVibe $APP/Contents/MacOS/
cp -R $BIN/Sparkle.framework $APP/Contents/Frameworks/
xcrun actool Resources/AppIcon.icon --compile $APP/Contents/Resources --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 27.0 --output-partial-info-plist /dev/null >/dev/null
# The notifications show the light icon whatever the system's icon style.
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon \
    --export-image --output-file $APP/Contents/Resources/SnapshotIcon.png --platform macOS --rendition Default \
    --width 152 --height 152 --scale 1 >/dev/null
plutil -create xml1 $APP/Contents/Info.plist
plutil -insert CFBundleIdentifier -string io.github.dvdsanyi.stayvibe.snapshot $APP/Contents/Info.plist
plutil -insert CFBundleExecutable -string StayVibe $APP/Contents/Info.plist
plutil -insert CFBundleIconName -string AppIcon $APP/Contents/Info.plist
plutil -insert CFBundleShortVersionString -string "$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 1.0.0)" $APP/Contents/Info.plist
codesign --force --deep --sign - $APP
touch $TMP/started
open -W -n $APP --args --snapshot "$PWD/docs"
if [[ docs/screenshot-en.png -nt $TMP/started && docs/screenshot-zh.png -nt $TMP/started ]]; then
    echo "wrote docs/screenshot-en.png and docs/screenshot-zh.png"
else
    echo "macOS kept another app in front, so nothing was written; run this again without typing elsewhere"
    exit 1
fi
