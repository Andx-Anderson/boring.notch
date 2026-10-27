#!/bin/bash
# Build this fork, sign it with the local Developer ID, and install it over /Applications.
# Signing with a stable identity is what keeps Calendar / Camera permissions across rebuilds;
# an ad-hoc build would ask again every time.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=com.andxlab.boringnotch
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
: "${SIGN_ID:?no Developer ID Application identity found in the keychain}"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build -quiet

APP=build/dd/Build/Products/Release/boringNotch.app
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
ENT=build/app.entitlements
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" boringNotch/boringNotch.entitlements > "$ENT"

sign() { codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"; }

# Inside out: nested code first, the app last.
sign "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign "$SPARKLE/Updater.app"
sign "$SPARKLE/Autoupdate"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/Frameworks/Lottie.framework"
sign "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
sign --entitlements BoringNotchXPCHelper/BoringNotchXPCHelper.entitlements \
  "$APP/Contents/XPCServices/BoringNotchXPCHelper.xpc"
sign --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

pkill -x boringNotch 2>/dev/null || true
sleep 1
# Keep whatever was installed (upstream's build the first time) instead of overwriting it.
if [ -d /Applications/boringNotch.app ]; then
  mv /Applications/boringNotch.app "build/previous-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$APP" /Applications/boringNotch.app
open /Applications/boringNotch.app
echo "installed $(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString) as $BUNDLE_ID"
