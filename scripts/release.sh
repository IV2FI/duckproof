#!/bin/bash
# Builds, signs and notarizes a release, tags it and publishes it on GitHub.
#   ./scripts/release.sh 1.0.1
# Needs the Developer ID certificates in the keychain, the "duckproof" notarytool profile and `gh` logged in.
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The Developer ID identities are looked up in the keychain rather than written here.
identity() { security find-identity -v ${2:-} | sed -nE "s/.*\"($1: [^\"]+)\".*/\1/p" | head -1; }
APP_ID="$(identity "Developer ID Application" "-p codesigning")"
PKG_ID="$(identity "Developer ID Installer")"
[ -n "$APP_ID" ] && [ -n "$PKG_ID" ] || { echo "Developer ID certificates not found in the keychain." >&2; exit 1; }
cd "$ROOT"

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }

DUCKPROOF_VERSION="$VERSION" DUCKPROOF_BUILD="$(git rev-list --count HEAD)" \
APP_SIGN_ID="$APP_ID" PKG_SIGN_ID="$PKG_ID" \
NOTARY_PROFILE=unduck \
  ./scripts/build.sh

spctl -a -t install "build/Duckproof-$VERSION.pkg"
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "build/Duckproof-$VERSION.pkg" --title "Duckproof $VERSION" --generate-notes
