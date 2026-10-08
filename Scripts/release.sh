#!/bin/zsh
# Builds a downloadable Switchcraft.dmg plus its Sparkle appcast and, with --publish, a GitHub release.
#   Scripts/release.sh 1.0.0             # build/Switchcraft.dmg and build/appcast.xml only
#   Scripts/release.sh 1.0.0 --publish   # also tag v1.0.0 and upload both to GitHub Releases
# Needs: Xcode, xcodegen, gh (for --publish), and the Sparkle signing key in the login keychain
# (made once by Sparkle's generate_keys). dmgbuild is installed into build/.venv on first use.
# DOWNLOAD_BASE=http://127.0.0.1:8765 points the appcast at a local server for an update test.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: Scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 64; }

# Version: marketing version from the argument, build number from the commit count.
BUILD=$(git rev-list --count HEAD)
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
Scripts/build.sh Release

# Installer window.
[[ -x build/.venv/bin/dmgbuild ]] || { python3 -m venv build/.venv && build/.venv/bin/pip install -q dmgbuild; }
xcrun swiftc -O Scripts/make-dmg-background.swift -o build/make-dmg-background
build/make-dmg-background build/dmg >/dev/null
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff >/dev/null 2>&1
rm -f build/Switchcraft.dmg
build/.venv/bin/dmgbuild -s Scripts/dmg-settings.py -D app=build/Switchcraft.app -D background=build/dmg/background.tiff \
  "Switchcraft" build/Switchcraft.dmg >/dev/null
hdiutil verify -quiet build/Switchcraft.dmg
SHA=$(shasum -a 256 build/Switchcraft.dmg | cut -d' ' -f1)
SIZE=$(du -h build/Switchcraft.dmg | cut -f1 | tr -d ' ')
echo "Built build/Switchcraft.dmg ($SIZE, version $VERSION build $BUILD)"
echo "SHA-256 $SHA"

# The appcast Sparkle reads: this release only, its DMG signed with the EdDSA key, and the commits
# since the previous release as notes. Sparkle compares <sparkle:version> with CFBundleVersion.
REPO=mustafa4101996ahmed/switchcraft
PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)
CHANGES=$(git log --no-merges --format='%s' ${PREVIOUS:+$PREVIOUS..}HEAD | grep -v '^Release ' || true)
SIGNATURE=$(build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Switchcraft.dmg)
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Switchcraft</title>
    <item>
      <title>Switchcraft $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <description><![CDATA[<ul>$([[ -n "$CHANGES" ]] && sed 's|.*|<li>&</li>|' <<< "$CHANGES" | tr -d '\n')</ul>]]></description>
      <enclosure url="${DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$VERSION}/Switchcraft.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout build/appcast.xml
echo "Built build/appcast.xml"

[[ "$PUBLISH" == "--publish" ]] || exit 0

cat > build/release-notes.md <<NOTES
## What's new

$(sed 's/^/- /' <<< "$CHANGES")

Switchcraft 1.2 and later install updates themselves: when one is out, click **Install Update**.

## Install

1. Download **Switchcraft.dmg** below and open it.
2. Drag **Switchcraft** into **Applications**.
3. Open it from Applications. Switchcraft isn't notarized by Apple yet, so the first time macOS
   says it can't check the app: open **System Settings › Privacy & Security**, scroll down and
   click **Open Anyway**. You only do this once.
4. Follow the welcome guide and allow **Input Monitoring** when asked.

Requires an Apple Silicon MacBook on macOS 14 or later.

**SHA-256** \`$SHA\`
NOTES
git add project.yml
git commit -q -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" build/Switchcraft.dmg build/appcast.xml --title "Switchcraft $VERSION" --notes-file build/release-notes.md --latest
echo "Published https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/v$VERSION"
