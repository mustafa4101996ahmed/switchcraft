#!/bin/zsh
# Builds Switchcraft.app (Release) into build/Switchcraft.app.
#   Scripts/build.sh            # Release
#   Scripts/build.sh Debug      # Debug
#   Scripts/build.sh Release SETTING=value …   # extra build settings go to xcodebuild
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
shift $(( $# > 0 ? 1 : 0 ))

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi

xcodebuild -project Switchcraft.xcodeproj -scheme Switchcraft -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData "$@" build | grep -E '(error|warning): |BUILD (SUCCEEDED|FAILED)' || true

APP="build/DerivedData/Build/Products/$CONFIG/Switchcraft.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
rm -rf build/Switchcraft.app
ditto "$APP" build/Switchcraft.app

# Sign with the local identity from Scripts/setup-signing.sh when it exists: a stable identity
# keeps the Input Monitoring permission across rebuilds. Otherwise the ad-hoc signature stays.
IDENTITY=$(security find-identity -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
  | awk '/"Switchcraft Local Signing"/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  # Sparkle's helpers are re-signed too, so the whole update path carries the same identity. Its XPC
  # services exist only for sandboxed apps; Switchcraft isn't sandboxed, so they're dropped.
  SPARKLE=build/Switchcraft.app/Contents/Frameworks/Sparkle.framework
  rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
  codesign --force --sign "$IDENTITY" -o runtime "$SPARKLE/Versions/B/Autoupdate"
  codesign --force --sign "$IDENTITY" -o runtime "$SPARKLE/Versions/B/Updater.app"
  codesign --force --sign "$IDENTITY" "$SPARKLE"
  codesign --force --sign "$IDENTITY" build/Switchcraft.app/Contents/Frameworks/SwitchcraftCore.framework
  codesign --force --sign "$IDENTITY" build/Switchcraft.app
  codesign --verify --strict build/Switchcraft.app
  echo "Signed with Switchcraft Local Signing"
else
  echo "Ad-hoc signed (run Scripts/setup-signing.sh once to keep permissions across rebuilds)"
fi
echo "Built $(pwd)/build/Switchcraft.app"
