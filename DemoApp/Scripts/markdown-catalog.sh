#!/usr/bin/env bash
# Draws the style catalogue to PNGs on the Mac, with a built app:
#   markdown-catalog.sh <app> <folder> [extra launch arguments]
# It waits for the manifest the app writes last, and doesn't take the front.
set -euo pipefail
APP="$1"; OUT="$2"; shift 2
rm -rf "$OUT"
open -g -n "$APP" --args -openTab catalog -catalogShots "$OUT" -catalogQuit YES -AppleLanguages "(en)" "$@"
for _ in $(seq 1 600); do
  [ -f "$OUT/manifest.json" ] && exit 0
  sleep 1
done
echo "no manifest in $OUT after 10 minutes" >&2
exit 1
