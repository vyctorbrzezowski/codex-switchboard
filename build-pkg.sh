#!/usr/bin/env bash
# Builds a macOS .pkg installer from the local .app bundle.
#
# Optional variables:
#   PRODUCT_NAME   App bundle filename without .app.
#   BUNDLE_ID      CFBundleIdentifier (also used as pkg identifier).
#   PKG_NAME       Output .pkg filename.
#   VERSION        Output/package display version string.
#   PACKAGE_VERSION pkgbuild-compatible package version. Defaults to VERSION without prerelease suffix.
#
# Usage:
#   ./build-pkg.sh
#   VERSION=1.0.9-beta.1 ./build-pkg.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PRODUCT_NAME="${PRODUCT_NAME:-CodexSwitchboard}"
BUNDLE_ID="${BUNDLE_ID:-app.codexswitchboard.menubar}"
PKG_NAME="${PKG_NAME:-CodexSwitchboard}"
VERSION="${VERSION:-1.0.9-beta.1}"
PACKAGE_VERSION="${PACKAGE_VERSION:-${VERSION%%-*}}"

APP_SRC="${ROOT}/dist/${PRODUCT_NAME}.app"
if [[ ! -d "$APP_SRC" ]]; then
	echo "error: .app not found at $APP_SRC — run ./build-app.sh first." >&2
	exit 1
fi

OUT_DIR="${ROOT}/dist"
mkdir -p "$OUT_DIR"

PKG_OUT="${OUT_DIR}/${PKG_NAME}-${VERSION}.pkg"
rm -f "$PKG_OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto --noextattr --norsrc "$APP_SRC" "${STAGE}/${PRODUCT_NAME}.app"

echo "Building installer package..."
COPYFILE_DISABLE=1 pkgbuild \
	--root "$STAGE" \
	--install-location /Applications \
	--identifier "$BUNDLE_ID" \
	--version "$PACKAGE_VERSION" \
	--filter '/\._[^/]*$' \
	--filter '/\.DS_Store$' \
	"$PKG_OUT"

echo "OK: $PKG_OUT"
echo "   Install: sudo installer -pkg \"$PKG_OUT\" -target /"
