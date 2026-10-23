#!/bin/bash
# Builds build/ExoKey.app. Usage: scripts/build_app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

if [ ! -f data/dict/en.exd ]; then
  echo "Dictionaries missing: run scripts/fetch_dicts.sh first" >&2
  exit 1
fi

swift build -c release --arch arm64

APP=build/ExoKey.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/ExoKey"
cp "$BIN" "$APP/Contents/MacOS/ExoKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp data/dict/*.exd "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Stable signing identity keeps macOS permissions between rebuilds (see scripts/make_dev_cert.sh)
IDENTITY="${SIGN_IDENTITY:-ExoKey Dev}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --options runtime -s "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' not found, ad-hoc signing (permissions reset after each build)"
  codesign --force --deep -s - "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x ExoKey 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/ExoKey.app
  cp -R "$APP" /Applications/
  open /Applications/ExoKey.app
  echo "Installed to /Applications"
fi
