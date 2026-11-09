#!/bin/bash
# Copies the keyboard debug log from the connected iPhone to ios/keyboard.log
cd "$(dirname "$0")"
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' | head -1)
xcrun devicectl device copy from --device "$UDID" --domain-type appGroupDataContainer \
  --domain-identifier group.com.jandiradmin.exokeymobile --source Library/keyboard.log --destination keyboard.log >/dev/null || exit 1
wc -l < keyboard.log
