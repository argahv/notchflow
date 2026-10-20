#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTCHFLOW_SIGN_IDENTITY:?Set NOTCHFLOW_SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTCHFLOW_NOTARY_PROFILE:?Set NOTCHFLOW_NOTARY_PROFILE to an existing notarytool keychain profile}"
test -d build/NotchFlow.app
codesign --force --options runtime --timestamp --entitlements Resources/NotchFlow.entitlements \
  --sign "$NOTCHFLOW_SIGN_IDENTITY" build/NotchFlow.app
codesign --verify --deep --strict --verbose=2 build/NotchFlow.app
ditto -c -k --keepParent build/NotchFlow.app build/NotchFlow-notarization.zip
xcrun notarytool submit build/NotchFlow-notarization.zip --keychain-profile "$NOTCHFLOW_NOTARY_PROFILE" --wait
xcrun stapler staple build/NotchFlow.app
xcrun stapler validate build/NotchFlow.app
