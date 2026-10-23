#!/bin/bash
# Usage: scripts/release.sh 0.1.0
# Builds the app, packs build/ExoKey-<ver>.zip, tags v<ver> and publishes a GitHub release (needs `gh auth login` once).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
VER="${1:?version, e.g. 0.1.0}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
scripts/build_app.sh
ZIP="build/ExoKey-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/ExoKey.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
git add Resources/Info.plist
git commit -m "Release $VER" || true
git tag -f "v$VER"
git push origin HEAD
git push -f origin "v$VER"
NOTES="docs/release-notes/$VER.md"
if gh auth status >/dev/null 2>&1; then
  gh release delete "v$VER" -y --repo jandiradmin/ExoKey 2>/dev/null || true
  gh release create "v$VER" "$ZIP" "$ZIP.sha256" --repo jandiradmin/ExoKey --title "ExoKey $VER" \
     $( [ -f "$NOTES" ] && echo --notes-file "$NOTES" || echo --generate-notes ) --prerelease
  echo "Published: https://github.com/jandiradmin/ExoKey/releases/tag/v$VER"
else
  echo "gh is not logged in. Run: gh auth login   — or upload $ZIP manually at https://github.com/jandiradmin/ExoKey/releases/new?tag=v$VER"
fi
