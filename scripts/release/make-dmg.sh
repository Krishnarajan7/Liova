#!/bin/bash
# Packages a built Liova.app into a compressed, drag-to-install DMG with a checksum.
#
#   scripts/release/make-dmg.sh <path/to/Liova.app> <version> <output-dir>
set -euo pipefail

APP="$1"
VERSION="$2"
OUT="$3"
NAME="Liova-$VERSION"

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/If Liova won't open.txt" <<'TXT'
Liova is free and open source, and isn't notarized by Apple yet, so the first time you open
it macOS asks you to confirm:

1. Drag Liova into Applications, then open it.
2. If macOS says it can't verify Liova, open System Settings > Privacy & Security,
   scroll down, and click "Open Anyway" next to Liova.

You only need to do this once. Source code: https://github.com/Krishnarajan7/Liova
TXT

mkdir -p "$OUT"
rm -f "$OUT/$NAME.dmg"
hdiutil create -quiet -volname "Liova $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT/$NAME.dmg"
hdiutil verify -quiet "$OUT/$NAME.dmg"
( cd "$OUT" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
echo "Built $OUT/$NAME.dmg"
cat "$OUT/$NAME.dmg.sha256"
