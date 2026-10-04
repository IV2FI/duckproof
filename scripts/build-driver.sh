#!/bin/bash
# Builds the "Unduck" virtual audio driver from the BlackHole sources (GPL-3.0, git submodule).
# The driver is renamed (name, UID, bundle ID, factory UUID) so it never clashes with an
# installed BlackHole, and because BlackHole's license forbids redistributing a modified
# build under the BlackHole name.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/BlackHole/BlackHole/BlackHole.c"
OUT="$ROOT/build/Unduck.driver"
VERSION="${UNDUCK_VERSION:-1.0.0}"
BUILD="${UNDUCK_BUILD:-1}"

# Never change these once released: the app and users' FaceTime settings rely on them.
DRIVER_BUNDLE_ID="app.unduck.driver"
DEVICE_NAME="Unduck"
FACTORY_UUID="4CDB72C4-6773-48EF-A19D-715729A5EDE0"

[ -f "$SRC" ] || git -C "$ROOT" submodule update --init vendor/BlackHole

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

clang -bundle -O2 -Wno-everything \
  -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -DkDriver_Name="\"$DEVICE_NAME\"" \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name="\"$DEVICE_NAME\"" \
  -DkDevice2_Name="\"$DEVICE_NAME Mirror\"" \
  -DkPlugIn_BundleID="\"$DRIVER_BUNDLE_ID\"" \
  -DkPlugIn_Icon="\"Unduck.icns\"" \
  -DkManufacturer_Name="\"Unduck (based on BlackHole by Existential Audio)\"" \
  -DkSampleRates="44100,48000" \
  -DkCanBeDefaultSystemDevice=false \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/Unduck" "$SRC"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>English</string>
	<key>CFBundleExecutable</key><string>Unduck</string>
	<key>CFBundleIdentifier</key><string>$DRIVER_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Unduck</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>CFPlugInFactories</key>
	<dict><key>$FACTORY_UUID</key><string>BlackHole_Create</string></dict>
	<key>CFPlugInTypes</key>
	<dict>
		<key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
		<array><string>$FACTORY_UUID</string></array>
	</dict>
</dict>
</plist>
PLIST

cp "$ROOT/vendor/BlackHole/LICENSE" "$OUT/Contents/Resources/LICENSE-BlackHole.txt"
[ -f "$ROOT/build/AppIcon.icns" ] && cp "$ROOT/build/AppIcon.icns" "$OUT/Contents/Resources/Unduck.icns"

echo "Driver: $OUT"
