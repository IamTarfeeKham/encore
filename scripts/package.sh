#!/bin/bash
# Builds a release zip for GitHub Releases: dist/Encore-<version>-macOS-arm64.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Encore}"
./build.sh
VERSION="$(defaults read "$PWD/build/$APP_NAME.app/Contents/Info" CFBundleShortVersionString)"
mkdir -p dist
ZIP="dist/$APP_NAME-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/$APP_NAME.app" "$ZIP"
shasum -a 256 "$ZIP"
echo "Packaged $ZIP"
