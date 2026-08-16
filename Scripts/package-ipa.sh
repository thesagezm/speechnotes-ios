#!/usr/bin/env bash
# Packages an unsigned .xcarchive into an .ipa for LiveContainer/SideStore.
# Usage: package-ipa.sh <path-to-xcarchive>
set -euo pipefail

ARCHIVE_PATH="${1:?usage: package-ipa.sh <path-to-xcarchive>}"
APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -n 1)"
if [ -z "$APP_PATH" ]; then
  echo "error: no .app found in $ARCHIVE_PATH" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist/Payload
cp -R "$APP_PATH" dist/Payload/

# Strip any stray signature so sideload tools treat it as cleanly unsigned.
rm -rf dist/Payload/*.app/_CodeSignature 2>/dev/null || true

(cd dist && zip -qry SpeechnotesIOS.ipa Payload)
echo "Packaged $(pwd)/dist/SpeechnotesIOS.ipa"
ls -lh dist/SpeechnotesIOS.ipa
