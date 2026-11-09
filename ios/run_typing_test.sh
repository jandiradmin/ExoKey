#!/bin/bash
# Runs the typing robot on the connected iPhone; prints the ROBOT lines. Usage: ios/run_typing_test.sh [testName]
cd "$(dirname "$0")"
ONLY=${1:+-only-testing:ExoKeyMobileUITests/TypingTests/$1}
xcodebuild test -project ExoKeyMobile.xcodeproj -scheme ExoKeyMobile -configuration Release -destination 'id=00008150-000054D23CF0401C' \
  -derivedDataPath build -allowProvisioningUpdates $ONLY 2>&1 | grep -E "ROBOT|error:|Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)|Testing failed" | head -150
