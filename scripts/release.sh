#!/usr/bin/env bash
# Build, package and sign a release for the in-app updater:
#   dist/WhatsAppWork-<version>-universal.dmg
#   dist/WhatsAppWork-<version>-universal.dmg.sig   (Ed25519, base64)
# The version is MARKETING_VERSION in apps/macos/project.yml. Publishing is
# a separate, deliberate step: the command is printed at the end. See
# docs/releasing.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/apps/macos"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' "$MAC/project.yml")"
[ -n "$VERSION" ] || { echo "release: MARKETING_VERSION not found in project.yml" >&2; exit 1; }

"$ROOT/scripts/build-core.sh"
if command -v xcodegen >/dev/null; then (cd "$MAC" && xcodegen generate); fi
# project.yml is the source of truth even if the generated project is stale.
(cd "$MAC" && xcodebuild -quiet -scheme WhatsAppWork -configuration Release \
  -derivedDataPath build/DerivedData-release MARKETING_VERSION="$VERSION" build)
APP="$MAC/build/DerivedData-release/Build/Products/Release/WhatsApp Work.app"
PLIST="$APP/Contents/Info.plist"

# The app must carry this version and the public half of YOUR release key,
# or every installed copy would reject the update.
BUILT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
[ "$BUILT" = "$VERSION" ] || { echo "release: built $BUILT, expected $VERSION" >&2; exit 1; }
EMBEDDED="$(/usr/libexec/PlistBuddy -c 'Print WWUpdatePublicKey' "$PLIST")"
SIGNER="$(swift "$ROOT/scripts/release-key.swift" public)"
[ "$EMBEDDED" = "$SIGNER" ] || {
  echo "release: the app's WWUpdatePublicKey does not match your release key" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/WhatsApp Work.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/WhatsAppWork-$VERSION-universal.dmg"
hdiutil create -quiet -volname "WhatsApp Work $VERSION" -srcfolder "$STAGE" \
  -format UDZO -ov "$DMG"
swift "$ROOT/scripts/release-key.swift" sign "$DMG" > "$DMG.sig"

echo "Built and signed WhatsApp Work $VERSION:"
echo "  $DMG"
echo "  $DMG.sig"
echo "Publish (the updater needs BOTH files on the release):"
echo "  gh release create v$VERSION \"$DMG\" \"$DMG.sig\" --title \"WhatsApp Work $VERSION\" --generate-notes"
