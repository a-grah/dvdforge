#!/bin/zsh
# Builds a signed, notarised dvdForge.app and packages it for distribution.
#
#   Scripts/release.sh
#
# Needs a "Developer ID Application" certificate in your keychain and a
# notarytool keychain profile, created once with:
#
#   xcrun notarytool store-credentials <profile> --apple-id <you@example.com> --team-id <TEAMID>
#
# Configuration (environment):
#   DVDFORGE_SIGN_IDENTITY   codesign identity (default: the first "Developer ID
#                            Application" identity in your keychain)
#   DVDFORGE_NOTARY_PROFILE  notarytool keychain profile (default: dvdforge-notary)
#
# Output: dist/dvdForge-<version>.zip containing the stapled app, plus its SHA-256.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

IDENTITY="${DVDFORGE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
PROFILE="${DVDFORGE_NOTARY_PROFILE:-dvdforge-notary}"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity found"; exit 1; }

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
BUILD_DIR="$ROOT/build/release"
APP="$BUILD_DIR/Build/Products/Release/dvdForge.app"
DIST="$ROOT/dist"
ZIP="$DIST/dvdForge-$VERSION.zip"

echo "==> dvdForge $VERSION, signing as: $IDENTITY"

echo "==> Building universal Release"
xcodegen generate --quiet
xcodebuild -project dvdForge.xcodeproj -scheme dvdForge -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- clean build | grep -E "error:|\*\* BUILD" || true
[[ -d "$APP" ]] || { echo "error: build failed"; exit 1; }
lipo -info "$APP/Contents/MacOS/dvdForge"

echo "==> Signing (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --entitlements DvdForge/DvdForge.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarising (this usually takes a few minutes)"
mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Checking as Gatekeeper will"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "==> Done: $ZIP"
