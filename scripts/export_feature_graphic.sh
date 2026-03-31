#!/usr/bin/env bash
# Converts feature_graphic.html → 1024x500 PNG using a headless browser.
# Requires: Chrome/Chromium installed
#
# Option 1: Using Chrome headless (macOS)
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --screenshot=feature_graphic.png \
  --window-size=1024,500 \
  "file://$(dirname "$0")/feature_graphic.html"

echo "Done → feature_graphic.png"
