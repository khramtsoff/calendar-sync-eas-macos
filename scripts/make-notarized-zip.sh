#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/make-notarized-zip.sh VERSION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-CalendarSync}"
SCHEME="${SCHEME:-CalendarSync}"
PROJECT="${PROJECT:-CalendarSync.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-JF25G9C7A8}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-calendarsync-notary}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/archives/$APP_NAME-$VERSION.xcarchive"
NOTARY_ZIP="$BUILD_DIR/notary/$APP_NAME-$VERSION-notary.zip"
DIST_DIR="$ROOT_DIR/dist"
FINAL_ZIP="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool not found: $1" >&2
    exit 127
  }
}

require_tool xcodegen
require_tool xcodebuild
require_tool codesign
require_tool ditto
require_tool xcrun
require_tool shasum

if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  echo "Signing identity not found in Keychain:" >&2
  echo "  $SIGN_IDENTITY" >&2
  echo "Import the Developer ID Application certificate for team $TEAM_ID, then rerun." >&2
  exit 3
fi

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR/archives" "$BUILD_DIR/notary" "$DIST_DIR"
rm -rf "$ARCHIVE_PATH" "$NOTARY_ZIP" "$FINAL_ZIP" "$FINAL_ZIP.sha256"

echo "Generating Xcode project..."
xcodegen generate

echo "Archiving $APP_NAME $VERSION..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  SKIP_INSTALL=NO

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH"

echo "Creating notarization upload zip..."
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  echo "Set NOTARY_KEYCHAIN_PROFILE to the notarytool Keychain profile name." >&2
  echo "Create it once with: xcrun notarytool store-credentials calendarsync-notary --apple-id ... --team-id $TEAM_ID --password ..." >&2
  exit 4
fi

echo "Submitting to Apple notarization..."
xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "Assessing Gatekeeper acceptance..."
spctl -a -vvv -t install "$APP_PATH"

echo "Creating final distribution zip..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP" | tee "$FINAL_ZIP.sha256"

echo "Created:"
echo "  $FINAL_ZIP"
echo "  $FINAL_ZIP.sha256"
