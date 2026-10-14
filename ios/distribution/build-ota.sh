#!/bin/bash
# Builds a Release Testing (Ad Hoc) .ipa of the iOS app with the embedded watch app and prepares the
# over-the-air install folder (ipa, manifest.plist, index.html, icons) for upload to the web server.
#
# Usage: ios/distribution/build-ota.sh [output dir]   (default: ~/Downloads/audiobookshelf-ota)
# Run `npm ci && npm run sync` first so the bundled web UI matches the native code.
set -euo pipefail

BASE_URL="https://cdn.kw.at/audiobookshelf"
HERE="$(cd "$(dirname "$0")" && pwd)"
IOS="$HERE/../App"
OUT="${1:-$HOME/Downloads/audiobookshelf-ota}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VERSION=$(cd "$IOS" && xcodebuild -workspace App.xcworkspace -scheme App -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}')
BUILD=$(cd "$IOS" && xcodebuild -workspace App.xcworkspace -scheme App -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *CURRENT_PROJECT_VERSION = /{print $2; exit}')
echo "Building Audiobookshelf $VERSION ($BUILD)"

xcodebuild archive -workspace "$IOS/App.xcworkspace" -scheme App -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$WORK/Audiobookshelf.xcarchive" \
  -allowProvisioningUpdates -quiet

xcodebuild -exportArchive -archivePath "$WORK/Audiobookshelf.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$HERE/ExportOptions-AdHoc.plist" -allowProvisioningUpdates -quiet

IPA=$(ls "$WORK"/export/*.ipa | head -1)
# The watch app must be embedded, and no spike secrets may ship in a publicly hosted ipa
CONTENTS=$(unzip -l "$IPA")
[[ "$CONTENTS" == *"Watch/AudiobookshelfWatch.app/Info.plist"* ]] || { echo "error: watch app missing from ipa" >&2; exit 1; }
[[ "$CONTENTS" != *"Secrets.plist"* ]] || { echo "error: Secrets.plist found in ipa" >&2; exit 1; }

mkdir -p "$OUT"
cp "$IPA" "$OUT/Audiobookshelf.ipa"
for file in manifest.plist index.html; do
  sed -e "s#__BASE_URL__#$BASE_URL#g" -e "s#__VERSION__#$VERSION#g" -e "s#__BUILD__#$BUILD#g" "$HERE/ota/$file.template" > "$OUT/$file"
done
ICON="$IOS/App/Assets.xcassets/AppIcon.appiconset/1024.png"
sips -z 512 512 "$ICON" --out "$OUT/icon-512.png" >/dev/null
sips -z 120 120 "$ICON" --out "$OUT/icon-120.png" >/dev/null

echo "Ready to upload to $BASE_URL:"
ls -lh "$OUT"
