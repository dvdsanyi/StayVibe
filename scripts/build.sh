#!/bin/zsh
# Builds build/StayVibe.app.
#   scripts/build.sh            build and sign (ad-hoc)
#   scripts/build.sh --install  also replace /Applications/StayVibe.app and launch it
# Env: VERSION (release.sh sets it).
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.0.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

FLAGS=(-c release --disable-keychain)  # public deps only; never prompt for keychain access
swift build $FLAGS
BIN=$(swift build $FLAGS --show-bin-path)

APP=build/StayVibe.app
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Resources,Frameworks}
cp $BIN/StayVibe $APP/Contents/MacOS/
cp -R $BIN/Sparkle.framework $APP/Contents/Frameworks/
cp -R Resources/*.lproj $APP/Contents/Resources/
# Icon Composer icon: light, dark, clear and tinted renditions in Assets.car, plus a fallback .icns.
xcrun actool Resources/AppIcon.icon --compile $APP/Contents/Resources --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 27.0 --output-partial-info-plist /dev/null >/dev/null
[[ -f $APP/Contents/Resources/Assets.car ]] || { echo "actool did not compile Resources/AppIcon.icon"; exit 1; }
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > $APP/Contents/Info.plist
# Until the Sparkle key exists, updates stay off.
if [[ $(plutil -extract SUPublicEDKey raw $APP/Contents/Info.plist) == __* ]]; then
    plutil -remove SUPublicEDKey $APP/Contents/Info.plist
fi
plutil -lint -s $APP/Contents/Info.plist

# Sign inside-out: Sparkle's helpers, the framework, then the app.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
for item in $SPARKLE/XPCServices/*.xpc $SPARKLE/Autoupdate $SPARKLE/Updater.app $APP/Contents/Frameworks/Sparkle.framework $APP; do
    codesign --force --sign - "$item"
done
echo "built $APP ($VERSION)"

if [[ ${1:-} == --install ]]; then
    osascript -e 'quit app id "io.github.dvdsanyi.stayvibe"' 2>/dev/null || true
    rm -rf /Applications/StayVibe.app
    mv $APP /Applications/  # move, so no second copy with the same bundle ID lingers in build/
    open /Applications/StayVibe.app
fi
