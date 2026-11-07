#!/bin/zsh
# Builds a universal Release MDown.app and packages it as build/MDown.dmg with a
# drag-to-Applications window. Requires Xcode and dmgbuild (pip install dmgbuild).
# Intermediate build products go to a temporary folder, not the project folder,
# so they never sync if the project lives in iCloud Drive or Dropbox.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${TMPDIR:-/tmp}/mdown-release-build"
mkdir -p build

xcodebuild -project MDown.xcodeproj -scheme MDown -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP="$DERIVED/Build/Products/Release/MDown.app"
codesign --force --deep --sign - "$APP"
rm -f build/MDown.dmg
dmgbuild -s Packaging/dmg-settings.py -D app="$APP" -D background=Packaging/background.png "MDown" build/MDown.dmg
hdiutil verify build/MDown.dmg
shasum -a 256 build/MDown.dmg
