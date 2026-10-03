#!/bin/zsh
# Builds Release and installs to /Applications/Switchcraft.app, then launches it.
# No sudo, no helper: Switchcraft reads the accelerometer as your user.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build.sh Release

DEST="/Applications/Switchcraft.app"
cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }
OLD_HASH="$( [[ -d "$DEST" ]] && cdhash "$DEST" || true )"
NEW_HASH="$(cdhash build/Switchcraft.app)"
# Retire the build installed under the app's previous name (ForceKeys).
if [[ -d /Applications/ForceKeys.app ]]; then
  pgrep -xq ForceKeys && { osascript -e 'quit app "ForceKeys"' || pkill -x ForceKeys || true; sleep 1; }
  rm -rf /Applications/ForceKeys.app
  tccutil reset ListenEvent com.forcekeys.app >/dev/null 2>&1 || true
  echo "Removed /Applications/ForceKeys.app (renamed to Switchcraft)"
fi
if pgrep -xq Switchcraft; then
  osascript -e 'quit app "Switchcraft"' || pkill -x Switchcraft || true
  sleep 1
fi
rm -rf "$DEST"
ditto build/Switchcraft.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "Installed $DEST"
# Local builds are ad-hoc signed, so macOS ties Input Monitoring to this exact binary. A changed
# build would show the switch as on while it no longer applies: clear the stale entry instead.
if [[ -n "$OLD_HASH" && "$OLD_HASH" != "$NEW_HASH" ]]; then
  tccutil reset ListenEvent com.switchcraft.app >/dev/null 2>&1 || true
  echo "New build: allow Input Monitoring again when Switchcraft asks (menu-bar icon › Allow…)."
fi
open "$DEST"
