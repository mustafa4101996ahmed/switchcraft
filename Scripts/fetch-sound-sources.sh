#!/bin/zsh
# Downloads the openly licensed recordings used by Scripts/build-sound-packs.swift.
#   Scripts/fetch-sound-sources.sh build/sources
set -euo pipefail
DEST="${1:-build/sources}"
mkdir -p "$DEST/freesound"

fetch_repo() { # repo, sparse path, target
  rm -rf "$DEST/.tmp" && git clone -q --depth 1 --filter=blob:none --sparse "https://github.com/$1.git" "$DEST/.tmp"
  git -C "$DEST/.tmp" sparse-checkout set --no-cone "/$2/" >/dev/null
  rm -rf "$DEST/$3" && mv "$DEST/.tmp/$2" "$DEST/$3" && rm -rf "$DEST/.tmp"
}
fetch_repo tplai/kbsim src/assets/audio kbsim                 # MIT © Thomas Lai
fetch_repo hainguyents13/mechvibes src/audio mechvibes        # MIT © 2021 Hai Nguyen

# Freesound previews, both CC0 1.0.
curl -fsSL -o "$DEST/freesound/mx-clear.mp3"  https://cdn.freesound.org/previews/412/412926_6895079-hq.mp3   # humi74
curl -fsSL -o "$DEST/freesound/mx-silent.mp3" https://cdn.freesound.org/previews/572/572978_12523644-hq.mp3  # bonesawmgraw
echo "Sources in $DEST"
