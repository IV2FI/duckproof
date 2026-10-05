#!/bin/bash
# Builds build/Duckproof.app (driver included) and build/Duckproof-<version>.pkg.
#
# With no environment variables: ad-hoc signing (what the GitHub releases use).
# Optional, with an Apple Developer account (removes the Gatekeeper warning):
#   APP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   PKG_SIGN_ID="Developer ID Installer: Your Name (TEAMID)" \
#   NOTARY_PROFILE=duckproof ./scripts/build.sh
# (profile created once with: xcrun notarytool store-credentials duckproof)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Duckproof.app"
export DUCKPROOF_VERSION="${DUCKPROOF_VERSION:-1.0.0}"
export DUCKPROOF_BUILD="${DUCKPROOF_BUILD:-1}"
BUNDLE_ID="app.duckproof.Duckproof"
export COPYFILE_DISABLE=1   # no ._ (extended attribute) files in the package
SIGN="${APP_SIGN_ID:--}"
# GitHub "owner/repo" used by the in-app update check (CI provides it, locally it's read from the git remote).
REPO="${GITHUB_REPOSITORY:-$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##' || true)}"

cd "$ROOT"
mkdir -p "$BUILD"

echo "▸ Icon"
swiftc -O scripts/icon/main.swift Sources/Duckproof/DuckArt.swift -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "▸ Audio driver"
"$ROOT/scripts/build-driver.sh"

echo "▸ App (arm64 + x86_64)"
swift build -c release --arch arm64 --scratch-path .build/arm64
swift build -c release --arch x86_64 --scratch-path .build/x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64/release/Duckproof .build/x86_64/release/Duckproof \
     -output "$APP/Contents/MacOS/Duckproof"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$BUILD/Duckproof.driver" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Duckproof</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Duckproof</string>
	<key>CFBundleDisplayName</key><string>Duckproof</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$DUCKPROOF_VERSION</string>
	<key>CFBundleVersion</key><string>$DUCKPROOF_BUILD</string>
	<key>LSMinimumSystemVersion</key><string>14.2</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Duckproof reads the audio FaceTime sends to its virtual device and forwards it to your headphones. Your real microphone is never recorded.</string>
	<key>DuckproofRepository</key><string>$REPO</string>
	<key>NSHumanReadableCopyright</key><string>GPL-3.0 · driver based on BlackHole (Existential Audio)</string>
</dict>
</plist>
PLIST

echo "▸ Signing ($SIGN)"
xattr -cr "$APP"
SIGN_OPTS=(--force --sign "$SIGN")
[ "$SIGN" != "-" ] && SIGN_OPTS+=(--options runtime --timestamp)
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Resources/Duckproof.driver"
codesign "${SIGN_OPTS[@]}" --entitlements "$ROOT/Resources/Duckproof.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Installer"
PKGROOT="$BUILD/pkgroot"
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT/Applications"
ditto --norsrc --noextattr --noacl "$APP" "$PKGROOT/Applications/Duckproof.app"
PKG="$BUILD/Duckproof-$DUCKPROOF_VERSION.pkg"
# Otherwise Installer "relocates" the update onto an old copy of the app found elsewhere on disk.
pkgbuild --analyze --root "$PKGROOT" "$BUILD/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/components.plist"
pkgbuild --root "$PKGROOT" --component-plist "$BUILD/components.plist" \
         --identifier "$BUNDLE_ID.pkg" --version "$DUCKPROOF_VERSION" \
         --scripts "$ROOT/Resources/pkg-scripts" --install-location / "$BUILD/Duckproof-component.pkg"
PRODUCT_OPTS=()
[ -n "${PKG_SIGN_ID:-}" ] && PRODUCT_OPTS+=(--sign "$PKG_SIGN_ID")
productbuild --package "$BUILD/Duckproof-component.pkg" ${PRODUCT_OPTS[@]+"${PRODUCT_OPTS[@]}"} "$PKG"
rm "$BUILD/Duckproof-component.pkg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarization"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "✓ $APP"
echo "✓ $PKG"
