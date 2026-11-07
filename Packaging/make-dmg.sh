#!/bin/zsh
# Builds a universal Release MDown.app and packages it as build/MDown.dmg with a
# drag-to-Applications window. Requires Xcode and dmgbuild (pip install dmgbuild).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project MDown.xcodeproj -scheme MDown -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=build/DerivedData/Build/Products/Release/MDown.app
codesign --force --deep --sign - "$APP"
rm -f build/MDown.dmg
dmgbuild -s Packaging/dmg-settings.py -D app="$APP" -D background=Packaging/background.png "MDown" build/MDown.dmg
hdiutil verify build/MDown.dmg
shasum -a 256 build/MDown.dmg
