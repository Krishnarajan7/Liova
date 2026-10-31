#!/bin/bash
# Renders the README images from the site's ?still= pages with headless Chrome, at 2x,
# saved as JPEG (the wallpaper's gradients are three times smaller than as PNG).
# Usage (from site/): pnpm build && pnpm preview & scripts/capture-stills.sh [OUT_DIR]
set -euo pipefail

out="${1:-../docs/images}"
base="${SITE_URL:-http://localhost:4173}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$out"
png="$(mktemp -d)"
trap 'rm -rf "$png"' EXIT

for name in music player agent charging download airpods; do
    "$chrome" --headless=new --hide-scrollbars --force-device-scale-factor=2 \
        --window-size=1200,505 --timeout=2500 \
        --screenshot="$png/$name.png" "$base/?still=$name" > /dev/null 2>&1
    sips -s format jpeg -s formatOptions 88 "$png/$name.png" --out "$out/notch-$name.jpg" > /dev/null
    echo "notch-$name.jpg"
done

# The site's link preview.
"$chrome" --headless=new --hide-scrollbars --window-size=1200,630 --timeout=2500 \
    --screenshot="public/og.png" "$base/?still=og" > /dev/null 2>&1
echo "public/og.png"
