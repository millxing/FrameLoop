#!/bin/bash
# Sign and notarize an existing native FrameLoop build; no rebuild or installation.
# Usage: bash scripts/release.sh [path/to/FrameLoop.app]
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Rob Schoen (6Y8QUTA3Z3)}"
PROFILE="${NOTARY_PROFILE:-framedl-notary}"
SOURCE="${1:-/Applications/FrameLoop.app}"
PLIST="$SOURCE/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "App not found: $SOURCE"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = com.robschoen.frameloop2 ]] || { echo 'Expected the native FrameLoop app.'; exit 1; }
# This signer handles the native app's single executable, not nested frameworks.
while IFS= read -r -d '' file; do
  if /usr/bin/file -b "$file" | grep -q 'Mach-O' && [[ "$file" != "$SOURCE/Contents/MacOS/FrameLoop" ]]; then
    echo "Additional native code needs a signing step: $file"
    exit 1
  fi
done < <(find "$SOURCE/Contents" -type f -print0)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
ARCH=$(lipo -archs "$SOURCE/Contents/MacOS/FrameLoop" | tr ' ' '-')
OUT="$PWD/releases/FrameLoop-${VERSION}-${BUILD}-${ARCH}"
[[ ! -e "$OUT" ]] || { echo "Output already exists: $OUT"; exit 1; }
security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP="$OUT/FrameLoop.app"
DMG="$OUT/FrameLoop-${VERSION}-${ARCH}.dmg"

notarize() {
  local file="$1" label="$2" id status
  # Save submission IDs so an interrupted run can be resumed with notarytool.
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --output-format json > "$OUT/$label-submission.json"
  id=$(plutil -extract id raw "$OUT/$label-submission.json")
  xcrun notarytool wait "$id" --keychain-profile "$PROFILE" --output-format json > "$OUT/$label-result.json"
  status=$(plutil -extract status raw "$OUT/$label-result.json")
  xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/$label-log.json"
  [[ "$status" = Accepted ]] || { echo "Apple returned $status. See $OUT/$label-log.json"; exit 1; }
  echo "Accepted: $label ($id)"
}

ditto "$SOURCE" "$APP"
xattr -cr "$APP"
# This Swift app needs no Electron JIT or library-validation exceptions.
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$WORK/FrameLoop.zip"
notarize "$WORK/FrameLoop.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/FrameLoop.app"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -volname FrameLoop -srcfolder "$WORK/stage" -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" > "$OUT/SHA256SUMS.txt"
echo "Release ready: $DMG"
