#!/bin/zsh
# Builds a universal Release MDown.app and packages it as build/MDown.dmg with a
# drag-to-Applications window. Requires Xcode and dmgbuild (pip install dmgbuild).
# Intermediate build products go to a temporary folder, not the project folder,
# so they never sync if the project lives in iCloud Drive or Dropbox.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/mdown-release-build}"
OUTPUT="${DMG_OUTPUT:-$PWD/build/MDown.dmg}"
DMGBUILD="${DMGBUILD:-dmgbuild}"
mkdir -p "${OUTPUT:h}"

xcodebuild -project MDown.xcodeproj -scheme MDown -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP="$DERIVED/Build/Products/Release/MDown.app"
# Sparkle ships ad-hoc signed helpers with their own flags/entitlements. Keep
# those signatures; never recursively re-sign them with --deep.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
codesign --verify --deep --strict "$APP"
rm -f "$OUTPUT"
"$DMGBUILD" -s Packaging/dmg-settings.py -D app="$APP" -D background=Packaging/background.png "MDown" "$OUTPUT"
hdiutil verify "$OUTPUT"
# Verify the actual shipped copy, including Sparkle's nested code.
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/mdown-dmg-verify.XXXXXX")
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach "$OUTPUT" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
codesign --verify --deep --strict "$MOUNT/MDown.app"
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"
trap - EXIT
shasum -a 256 "$OUTPUT"
