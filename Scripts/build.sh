#!/bin/zsh
# Builds Switchcraft.app (Release) into build/Switchcraft.app.
#   Scripts/build.sh            # Release
#   Scripts/build.sh Debug      # Debug
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi

xcodebuild -project Switchcraft.xcodeproj -scheme Switchcraft -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData build | grep -E '(error|warning): |BUILD (SUCCEEDED|FAILED)' || true

APP="build/DerivedData/Build/Products/$CONFIG/Switchcraft.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
rm -rf build/Switchcraft.app
ditto "$APP" build/Switchcraft.app
echo "Built $(pwd)/build/Switchcraft.app"
