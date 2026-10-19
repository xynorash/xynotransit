#!/usr/bin/env bash
# Headless Chrome screenshot of a URL at a given window size.
#   tool/shot.sh <url> <out.png> [width=1440] [height=900] [wait_ms=12000]
set -euo pipefail
URL=$1; OUT=$2; W=${3:-1440}; H=${4:-900}; WAIT=${5:-12000}
google-chrome-stable --headless=new --disable-gpu --use-angle=swiftshader --enable-unsafe-swiftshader \
  --hide-scrollbars --no-sandbox --force-device-scale-factor=1 \
  --window-size="$W,$H" --virtual-time-budget="$WAIT" --screenshot="$OUT" "$URL" >/dev/null 2>&1
test -s "$OUT"
