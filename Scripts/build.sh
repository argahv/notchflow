#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'NotchFlow requires macOS and Xcode. Run the Python bridge tests on other systems.' >&2
  exit 1
fi
python3 Scripts/generate_project.py
xcodebuild -project NotchFlow.xcodeproj -scheme NotchFlow -configuration Release \
  -derivedDataPath build/DerivedData ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
mkdir -p build
ditto build/DerivedData/Build/Products/Release/NotchFlow.app build/NotchFlow.app
echo 'Built build/NotchFlow.app (unsigned). For permissions and login items, sign in Xcode.'
