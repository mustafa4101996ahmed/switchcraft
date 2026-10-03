#!/bin/zsh
# Runs the unit tests (Swift Testing) for SwitchcraftCore.
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi
xcodebuild -project Switchcraft.xcodeproj -scheme Switchcraft -derivedDataPath build/DerivedData test \
  | grep -E '(error|warning): |✘|✔ Test run|Test run with|TEST (SUCCEEDED|FAILED)'
