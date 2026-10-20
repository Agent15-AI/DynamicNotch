#!/bin/zsh
# End-to-end Sparkle check: takes the app `./make.sh dist` just assembled, makes an old (100) and a new
# (101) copy under a test bundle identifier with a throwaway EdDSA key, serves a signed appcast from
# 127.0.0.1, launches the old copy and waits for Sparkle to download, verify and install the new one.
# The real app's settings are left alone; the test identifier's are removed afterwards. A second
# island and capsule show for half a minute while it runs.
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$ROOT/build/update-test
BUNDLE=dev.local.dynamicisland.updatetest
PORT=8932
SIGN=$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -d $ROOT/build/DynamicIsland.app ]] || { echo "Run ./make.sh dist first"; exit 1; }
rm -rf $WORK && mkdir -p $WORK/feed $WORK/old $WORK/new

# A throwaway key pair: the base64 seed (what generate_keys -x exports) and its public key.
KEYS=$(swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
SEED=${KEYS% *} PUBLIC=${KEYS#* }

copy() {  # destination, version, build number
  ditto $ROOT/build/DynamicIsland.app $1/DynamicIsland.app
  local plist=$1/DynamicIsland.app/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" -c "Set :CFBundleShortVersionString $2" \
    -c "Set :CFBundleVersion $3" -c "Set :SUPublicEDKey $PUBLIC" \
    -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" $plist
  codesign --force --sign - --identifier $BUNDLE $1/DynamicIsland.app
}

copy $WORK/new 0.0.2 101
ditto -c -k --norsrc --noextattr --keepParent $WORK/new/DynamicIsland.app $WORK/feed/DynamicNotch-0.0.2.zip
SIGNATURE=$(print -r -- $SEED | $SIGN --ed-key-file - -p $WORK/feed/DynamicNotch-0.0.2.zip)
cat > $WORK/feed/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DynamicNotch</title>
    <item>
      <title>0.0.2</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>101</sparkle:version>
      <sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="http://127.0.0.1:$PORT/DynamicNotch-0.0.2.zip" length="$(stat -f %z $WORK/feed/DynamicNotch-0.0.2.zip)" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
print -r -- $SEED | $SIGN --ed-key-file - $WORK/feed/appcast.xml

copy $WORK/old 0.0.1 100

# Fresh settings for the test identifier: no welcome, no login item, nothing touching the real menu
# bar or clipboard history, and update without asking.
defaults delete $BUNDLE >/dev/null 2>&1 || true
defaults write $BUNDLE onboarded -bool true
defaults write $BUNDLE launchAtLoginDefaulted -bool true
defaults write $BUNDLE menuBar -bool false
defaults write $BUNDLE clipboard -bool false
defaults write $BUNDLE SUAutomaticallyUpdate -bool true
defaults write $BUNDLE SUEnableAutomaticChecks -bool true
# A fresh install waits a day before its first scheduled check; an old last check makes one due now.
defaults write $BUNDLE SULastCheckTime -date "2020-01-01 00:00:00 +0000"

python3 -I -m http.server $PORT --bind 127.0.0.1 --directory $WORK/feed > $WORK/server.log 2>&1 &
SERVER=$!
cleanup() {
  set +e  # pkill finds nothing once the app has quit; keep cleaning up anyway.
  kill $SERVER 2>/dev/null
  pkill -f "$WORK/old/DynamicIsland.app/Contents/MacOS/DynamicIsland" 2>/dev/null
  sleep 2  # Sparkle's installer saves its last settings as it exits.
  defaults delete $BUNDLE >/dev/null 2>&1
  rm -rf ~/Library/Caches/$BUNDLE ~/Library/HTTPStorages/$BUNDLE ~/Library/Preferences/$BUNDLE.plist
}
trap cleanup EXIT

# Through LaunchServices, as a user would start it.
open -n $WORK/old/DynamicIsland.app
sleep 2
APPPID=$(pgrep -f "$WORK/old/DynamicIsland.app/Contents/MacOS/DynamicIsland" | head -1)
# Sparkle checks shortly after launch, downloads and verifies, then installs once the app quits.
for _ in {1..60}; do grep -q "GET /DynamicNotch-0.0.2.zip" $WORK/server.log && break; sleep 1; done
grep -q "GET /DynamicNotch-0.0.2.zip" $WORK/server.log || { echo "FAIL: Sparkle never downloaded the update"; cat $WORK/server.log; exit 1; }
sleep 8
kill -TERM $APPPID 2>/dev/null || true
for _ in {1..60}; do
  [[ $(defaults read $WORK/old/DynamicIsland.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) == 0.0.2 ]] && break
  sleep 1
done
VERSION=$(defaults read $WORK/old/DynamicIsland.app/Contents/Info.plist CFBundleShortVersionString)
if [[ $VERSION == 0.0.2 ]] && codesign --verify --deep --strict $WORK/old/DynamicIsland.app; then
  echo "OK: Sparkle updated the ad-hoc signed app from 0.0.1 to $VERSION and its signature verifies"
else
  echo "FAIL: app is still $VERSION"; log show --last 3m --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle"' 2>/dev/null | tail -20
  exit 1
fi
