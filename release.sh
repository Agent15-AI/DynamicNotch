#!/bin/bash
# Publish a release: ./release.sh 0.1.1
#
# Bumps the version, builds and signs the zip and appcast (`./make.sh dist`),
# commits, tags and pushes, publishes the GitHub release - which is what every
# installed copy's update check reads - and points the Homebrew cask at it.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
REPO=Agent15-AI/DynamicNotch
TAP=Agent15-AI/homebrew-tap
CASK=Casks/dynamicnotch.rb
PLIST=Resources/Info.plist

[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first"; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION is already released"; exit 1; fi
PREVIOUS="$(git describe --tags --abbrev=0)"

# Sparkle compares CFBundleVersion, so it goes up by one every release.
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $PLIST) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST
./make.sh dist
ZIP="dist/DynamicNotch-$VERSION.zip"

NOTES="$(git log --format='- %s' "$PREVIOUS..HEAD")"
git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" dist/appcast.xml --repo "$REPO" --title "DynamicNotch $VERSION" \
  --notes "$NOTES

Install: \`brew install --cask agent15-ai/tap/dynamicnotch\`, or download the zip below. Installed copies update themselves."

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
FILE_SHA="$(gh api "repos/$TAP/contents/$CASK" --jq .sha)"
gh api "repos/$TAP/contents/$CASK" --jq .content | base64 -d \
  | sed -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" > dist/dynamicnotch.rb
gh api -X PUT "repos/$TAP/contents/$CASK" -f message="dynamicnotch $VERSION" \
  -f content="$(base64 -i dist/dynamicnotch.rb)" -f sha="$FILE_SHA" >/dev/null

echo "released $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
