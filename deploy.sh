#!/bin/bash
# Publishes the iPhone + Apple Watch Ad Hoc install (ipa, manifest.plist, index.html, icons) to
# https://cdn.kw.at/audiobookshelf/.
#
#   ./deploy.sh        builds it (npm run sync + ios/distribution/build-ota.sh into build/ota) and shows what an
#                      upload would change: a dry run, nothing on the server changes.
#   ./deploy.sh --go   uploads exactly that build, without building again, so what goes up is what the dry
#                      run showed. Run ./deploy.sh first.
#
# Bump CURRENT_PROJECT_VERSION in ios/App/App.xcodeproj before building, or installed devices won't see an update.
# Xcode must be running (cloud signing needs its account session).
# The server's files belong to cdn-deploy:www-data, and cdn-deploy can't change files it doesn't own, so rsync
# keeps no owner, group, permissions or directory times.
set -euo pipefail
cd "$(dirname "$0")"

SRC="./build/ota/"
DEST="cdn-kw:/var/www/cdn.kw.at/audiobookshelf/"

# Only ever a folder of its own under the CDN root, which holds many unrelated projects.
if [[ ! "$DEST" =~ ^cdn-kw:/var/www/cdn\.kw\.at/[A-Za-z0-9._-]+/$ ]] || [[ "$DEST" == *"/../"* ]] || [[ "$DEST" == *"/./"* ]]; then
  echo "error: DEST must be a subfolder of /var/www/cdn.kw.at/, not the CDN root or anything else: $DEST" >&2
  exit 1
fi

case "${1:-}" in
  --go) MODE=go ;;
  "") MODE=dry ;;
  *) echo "usage: ./deploy.sh [--go]" >&2; exit 2 ;;
esac

if [[ "$MODE" == dry ]]; then
  rm -rf "$SRC"
  npm run sync
  ios/distribution/build-ota.sh "$SRC"
fi

if [[ ! -d "$SRC" ]] || [[ -z "$(ls -A "$SRC")" ]]; then
  echo "error: $SRC is missing or empty. Run ./deploy.sh (without --go) first: it builds and shows the dry run." >&2
  exit 1
fi
for file in Audiobookshelf.ipa manifest.plist index.html; do
  [[ -s "$SRC$file" ]] || { echo "error: $SRC$file is missing; the build didn't finish." >&2; exit 1; }
done

OPTIONS=(-rltvz --omit-dir-times --no-perms --delete --exclude=.git --exclude=.DS_Store)
if [[ "$MODE" == dry ]]; then
  echo "--- dry run: nothing changes on the server. ./deploy.sh --go uploads this build."
  rsync "${OPTIONS[@]}" --dry-run "$SRC" "$DEST"
else
  rsync "${OPTIONS[@]}" "$SRC" "$DEST"
  echo "--- deployed to https://cdn.kw.at/audiobookshelf/"
fi
