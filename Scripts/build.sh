#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'NotchFlow requires macOS and Xcode. Run the Python bridge tests on other systems.' >&2
  exit 1
fi
python3 Scripts/generate_project.py
# A release stamps its own version; local builds keep the project's.
VERSION_ARGS=()
[[ -n "${NOTCHFLOW_VERSION:-}" ]] && VERSION_ARGS+=("MARKETING_VERSION=$NOTCHFLOW_VERSION")
[[ -n "${NOTCHFLOW_BUILD:-}" ]] && VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$NOTCHFLOW_BUILD")
xcodebuild -project NotchFlow.xcodeproj -scheme NotchFlow -configuration Release \
  -derivedDataPath build/DerivedData ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} build
mkdir -p build
rm -rf build/NotchFlow.app
ditto build/DerivedData/Build/Products/Release/NotchFlow.app build/NotchFlow.app
# Optional for local builds: sign with your identity so macOS keeps privacy permissions (Downloads,
# Desktop) across rebuilds. An unsigned build is a new app to macOS each time and asks again.
if [[ -n "${NOTCHFLOW_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp=none --entitlements Resources/NotchFlow.entitlements \
    --sign "$NOTCHFLOW_SIGN_IDENTITY" build/NotchFlow.app
  echo "Built build/NotchFlow.app, signed for local use."
else
  echo 'Built build/NotchFlow.app (unsigned). For permissions and login items, set NOTCHFLOW_SIGN_IDENTITY or sign in Xcode.'
fi
