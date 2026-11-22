#!/bin/bash
# Builds the app (Apple Silicon) into ./build.
#
#   ./build.sh                  build build/Encore.app
#   ./build.sh --run            build and open it
#   ./build.sh --install        build and copy it to /Applications
#   APP_NAME="My Name" ./build.sh --install   use a different app name
#   BUNDLE_ID=com.example.encore ./build.sh   use a different bundle ID (separate settings/sign-in)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="${APP_NAME:-Encore}"
APP="build/$APP_NAME.app"
ARCH="arm64"   # Apple Silicon only for now

swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/Encore"

# App icon (generated once from scripts/make_icon.swift).
if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Encore"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP/Contents/Info.plist"
if [ -n "${BUNDLE_ID:-}" ]; then plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with the hardened runtime and the sandbox entitlements.
# (For public releases, sign with a Developer ID and notarize instead — see README.)
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements Resources/Encore.entitlements "$APP"
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  DEST="/Applications/$APP_NAME.app"
  BUNDLE_ID="$(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier)"
  if [ -d "$DEST" ] && [ "$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$BUNDLE_ID" ]; then
    # Never overwrite a different app that happens to share the name.
    echo "A different '$APP_NAME.app' is already in /Applications; not replacing it." >&2
    exit 1
  fi
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  APP="$DEST"
  echo "Installed to $APP"
fi
if [[ " $* " == *" --run "* ]]; then open "$APP"; fi
