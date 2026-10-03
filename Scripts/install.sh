#!/bin/zsh
# Builds Release and installs to /Applications/Switchcraft.app, then launches it.
# No sudo, no helper: Switchcraft reads the accelerometer as your user.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build.sh Release

DEST="/Applications/Switchcraft.app"
# macOS ties Input Monitoring to the app's designated requirement: the certificate for builds signed
# with Scripts/setup-signing.sh (stable), or the exact binary hash for ad-hoc builds (new every build).
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'; }
OLD_REQ="$( [[ -d "$DEST" ]] && requirement "$DEST" || true )"
NEW_REQ="$(requirement build/Switchcraft.app)"
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
# A changed identity would leave the switch looking on while it no longer applies: clear it instead.
if [[ -n "$OLD_REQ" && "$OLD_REQ" != "$NEW_REQ" ]]; then
  tccutil reset ListenEvent com.switchcraft.app >/dev/null 2>&1 || true
  echo "New build: allow Input Monitoring again when Switchcraft asks (menu-bar icon › Allow…)."
fi
open "$DEST"
