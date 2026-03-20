#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="${PRODUCT_NAME:-MacCleanerUI}"
APP_NAME="${APP_NAME:-MacCleaner}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-MacCleaner}"
BUNDLE_ID="${BUNDLE_ID:-com.example.MacCleaner}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-13.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$ROOT_DIR/.build/package"
APP_DIR="$PACKAGE_DIR/$APP_NAME.app"
DIST_APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_DIR="$PACKAGE_DIR/dmg"
INFO_TEMPLATE="$ROOT_DIR/Packaging/Info.plist.template"

ARM_BINARY="$ROOT_DIR/.build/arm64-apple-macosx/release/$PRODUCT_NAME"
INTEL_BINARY="$ROOT_DIR/.build/x86_64-apple-macosx/release/$PRODUCT_NAME"
UNIVERSAL_BINARY="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
PKG_PATH="$DIST_DIR/$APP_NAME.pkg"

echo "Building release binaries..."
swift build -c release --arch arm64 --product "$PRODUCT_NAME"
swift build -c release --arch x86_64 --product "$PRODUCT_NAME"

rm -rf "$DIST_DIR" "$PACKAGE_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DMG_DIR" "$DIST_DIR"

echo "Creating universal app bundle..."
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$UNIVERSAL_BINARY"
chmod +x "$UNIVERSAL_BINARY"

sed \
    -e "s|__APP_NAME__|$APP_NAME|g" \
    -e "s|__EXECUTABLE_NAME__|$EXECUTABLE_NAME|g" \
    -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__MIN_SYSTEM_VERSION__|$MIN_SYSTEM_VERSION|g" \
    "$INFO_TEMPLATE" > "$APP_DIR/Contents/Info.plist"

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "Signing app bundle..."
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "Copying app bundle..."
ditto "$APP_DIR" "$DIST_APP_DIR"

echo "Creating zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP_DIR" "$ZIP_PATH"

echo "Creating pkg installer..."
PKG_ARGS=(
    --component "$APP_DIR"
    --install-location /Applications
)

if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
    PKG_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY")
fi

pkgbuild "${PKG_ARGS[@]}" "$PKG_PATH"

echo "Creating dmg image..."
ditto "$APP_DIR" "$DMG_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" > /dev/null

echo ""
echo "Artifacts created:"
echo "  $DIST_APP_DIR"
echo "  $ZIP_PATH"
echo "  $PKG_PATH"
echo "  $DMG_PATH"
echo ""
echo "Note: ad-hoc signing is used by default. Gatekeeper will reject ad-hoc or unsigned artifacts on other Macs."
echo "For smoother distribution, set CODESIGN_IDENTITY to a Developer ID Application certificate,"
echo "set INSTALLER_SIGN_IDENTITY to a Developer ID Installer certificate, then notarize the app or installer."
