#!/bin/bash
# Build DynamicIsland.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/DynamicIsland.app"

# `./make.sh dist` builds the zip attached to a GitHub release instead of
# installing: ad-hoc signed, since a personal certificate is no help on anyone
# else's Mac and would put its owner's name in the signature.
DIST=""
if [ "$CONFIG" = dist ]; then DIST=1; CONFIG=release; fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/DynamicIsland"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sparkle, for updates. SwiftPM links it from beside the binary; in the bundle
# it lives in Frameworks, so the binary is told to look there too.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/DynamicIsland"

# The MediaRemote adapter must live in Resources - perl is handed absolute paths
# to the framework and the script at runtime.
cp -R Vendor/MediaRemoteAdapter.framework Vendor/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Resources/DynamicIsland.icns "$APP/Contents/Resources/"
# OCR runs in its own short-lived process; see Sources/OCRHelper.
cp "$BIN_DIR/di-ocr" "$APP/Contents/Resources/di-ocr"

# The downloader, if there is one to carry. Tools ▸ Convert prefers this copy
# over anything installed, so an app handed to someone else works on a Mac with
# no Homebrew. Optional: without it the panel says so and points at Homebrew.
# Get one with:
#   curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos -o Vendor/yt-dlp
#   chmod +x Vendor/yt-dlp
if [ -x Vendor/yt-dlp ]; then
  cp Vendor/yt-dlp "$APP/Contents/Resources/yt-dlp"
  # Signed on its own before the bundle is: a nested executable with a stale
  # signature invalidates the whole app's.
  codesign --force --sign - "$APP/Contents/Resources/yt-dlp" 2>/dev/null || true
  echo "bundled Vendor/yt-dlp"
fi

if [ -n "$DIST" ]; then
  cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
  codesign --force --sign - --identifier dev.local.dynamicisland "$APP"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
  ZIP="dist/DynamicNotch-$VERSION.zip"
  mkdir -p dist
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

  # Sparkle installs an update only when it is signed by the key whose public
  # half is SUPublicEDKey. The private half is in the releaser's keychain,
  # under the account "dynamicnotch" (Sparkle's generate_keys made it).
  SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
  SIGNATURE="$("$SIGN" --account dynamicnotch -p "$ZIP")"
  # Checked against the key the app carries, so no installed copy is ever
  # offered an update it would refuse.
  PUBLIC="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Resources/Info.plist)"
  ZIP_PATH="$ZIP" SIGNATURE="$SIGNATURE" PUBLIC="$PUBLIC" swift - <<'SWIFT' || { echo "the update signature does not match SUPublicEDKey"; exit 1; }
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: env["PUBLIC"]!)!)
let data = try Data(contentsOf: URL(fileURLWithPath: env["ZIP_PATH"]!))
exit(key.isValidSignature(Data(base64Encoded: env["SIGNATURE"]!)!, for: data) ? 0 : 1)
SWIFT

  # Attached to the release; SUFeedURL reads the latest release's copy.
  cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DynamicNotch</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/Agent15-AI/DynamicNotch/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/Agent15-AI/DynamicNotch/releases/download/v$VERSION/DynamicNotch-$VERSION.zip" length="$(stat -f %z "$ZIP")" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
  # SURequireSignedFeed: the feed carries a signature of its own.
  "$SIGN" --account dynamicnotch dist/appcast.xml
  echo "built $ZIP and dist/appcast.xml (sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1))"
  exit 0
fi

# Signed with a real identity when one exists, ad-hoc otherwise.
#
# This matters more than it looks. A TCC permission is recorded against the
# binary's cdhash, and an ad-hoc signature *is* a hash of the binary - so every
# rebuild produces a new identity and every previously granted permission stops
# applying. The row stays visible in System Settings, switched on, while the app
# is told it has no access. Measured exactly that: toggle on, preflight false.
#
# A Developer ID or Apple Development certificate gives a stable designated
# requirement instead, so one grant holds across every future build. A
# self-signed certificate cannot do this job: codesign will not use one until it
# is trusted for code signing, and trusting it needs an admin dialog.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -E "Developer ID Application|Apple Development" \
  | sed -E 's/.*\) ([A-F0-9]{40}) "(.*)"/\1/')"

if [ -n "$IDENTITY" ]; then
  if codesign --force --sign "$IDENTITY" --identifier dev.local.dynamicisland "$APP" 2>/dev/null; then
    echo "signed with stable identity ${IDENTITY:0:12}… (permissions survive rebuilds)"
  else
    echo "stable identity failed - falling back to ad-hoc (permissions reset each build)"
    codesign --force --sign - --identifier dev.local.dynamicisland "$APP"
  fi
else
  echo "no signing identity - ad-hoc (permissions reset each build)"
  codesign --force --sign - --identifier dev.local.dynamicisland "$APP"
fi

# Installed to /Applications, and moved rather than copied. macOS 27's menu
# bar restriction keeps an app's icons only for the copy LaunchServices
# resolves for its bundle id - so a second copy in build/, or one outside
# /Applications, hides the capsule itself the moment icons are hidden.
INSTALLED="/Applications/DynamicIsland.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -x DynamicIsland 2>/dev/null || true
rm -rf "$INSTALLED"
mv "$APP" "$INSTALLED"
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -f "$INSTALLED"

echo "installed $INSTALLED"
echo "Launch with: open $INSTALLED"
echo "(Running the binary directly bypasses the bundle Info.plist, and TCC aborts on first Bluetooth use.)"
