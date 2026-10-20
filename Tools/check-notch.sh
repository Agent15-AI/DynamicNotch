#!/bin/bash
# Opens the island on every tab and checks that none of them paint under the
# physical notch. See check-notch.swift for why a screenshot alone cannot tell.
set -uo pipefail
cd "$(dirname "$0")/.."

# make.sh installs here; a copy anywhere else is not the one macOS resolves.
APP="/Applications/DynamicIsland.app"
DOMAIN="dev.local.dynamicisland"
OUT="${TMPDIR:-/tmp}/notch-check"
mkdir -p "$OUT"

read -r NX NY NW NH < <(swift - <<'SWIFT'
import AppKit
let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
guard let l = s.auxiliaryTopLeftArea?.width, let r = s.auxiliaryTopRightArea?.width else {
    print("0 0 0 0"); exit(0)
}
let w = s.frame.width - l - r, h = s.safeAreaInsets.top
print("\(Int(s.frame.midX - w / 2)) 0 \(Int(w)) \(Int(h))")
SWIFT
)

if [ "$NW" -eq 0 ]; then
  echo "check-notch: no notched display, nothing to check"
  exit 0
fi
echo "notch rect: ${NW}x${NH} at x=${NX}"

FAIL=0
for TAB in home shelf tasks clock tools notes mixer; do
  defaults write "$DOMAIN" lastTab -string "$TAB"
  killall DynamicIsland 2>/dev/null
  sleep 1
  open "$APP" --args --open
  sleep 3.5
  screencapture -x -R"$NX,$NY,$NW,$NH" "$OUT/$TAB.png"
  printf '%-7s ' "$TAB"
  swift Tools/check-notch.swift "$OUT/$TAB.png" || FAIL=1
done

killall DynamicIsland 2>/dev/null
defaults write "$DOMAIN" lastTab -string home
exit $FAIL
