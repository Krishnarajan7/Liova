#!/bin/bash
# Signs a built Liova.app for release, inside out: the Now Playing framework, the `liova`
# CLI, then the app with the hardened runtime and exactly App/Liova.entitlements.
#
# Release builds are signed here with codesign rather than by Xcode, because the release
# certificate is self-signed: Xcode only offers identities this Mac trusts, codesign signs
# with any identity in the keychain. Liova checks updates against this signature (see
# docs/DISTRIBUTION.md), so it must pin the certificate, which the end of this script checks.
#
#   scripts/release/sign-app.sh <path/to/Liova.app> <identity, or - for ad-hoc>
set -euo pipefail

APP="$1"
IDENTITY="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTITLEMENTS="$ROOT/App/Liova.entitlements"

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

sign() {
    codesign --force --timestamp=none --options runtime -s "$IDENTITY" "$@"
}

for framework in "$APP"/Contents/Frameworks/*.framework; do
    [ -e "$framework" ] && sign "$framework"
done
[ -e "$APP/Contents/Helpers/liova" ] && sign "$APP/Contents/Helpers/liova"
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    echo "The app has get-task-allow; a release must not." >&2
    exit 1
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | grep '^designated')"
echo "$REQUIREMENT"
if [ "$IDENTITY" != "-" ] && ! grep -q "certificate leaf" <<< "$REQUIREMENT"; then
    echo "Signed with \"$IDENTITY\" but the requirement doesn't pin a certificate." >&2
    exit 1
fi
echo "Signed $APP with ${IDENTITY/#-/ad-hoc}"
