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
# Signature for in-app updates (the app only installs zips signed with this key).
KEY="$HOME/.config/encore/update-signing-key"
if [ -f "$KEY" ]; then
  swift scripts/sign_update.swift "$KEY" "$ZIP" > "$ZIP.sig"
  echo "Signed $ZIP.sig"
else
  echo "warning: no update signing key at $KEY; in-app updates won't install this release" >&2
fi
echo "Packaged $ZIP"
