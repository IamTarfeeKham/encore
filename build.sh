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

# The updater helper (not sandboxed; it only ever replaces this app with a release
# zip signed with the release key). Signed first, then the app around it.
HELPER="$APP/Contents/Helpers/Encore Updater.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$(dirname "$BIN")/EncoreUpdater" "$HELPER/Contents/MacOS/EncoreUpdater"
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.ytmusicmac.updater</string>
  <key>CFBundleName</key><string>Encore Updater</string>
  <key>CFBundleExecutable</key><string>EncoreUpdater</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none --options runtime "$HELPER"

# Desktop widgets (a WidgetKit extension).
APPEX="$APP/Contents/PlugIns/EncoreWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$(dirname "$BIN")/EncoreWidgets" "$APPEX/Contents/MacOS/EncoreWidgets"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
APP_BUILD="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
APP_ID="${BUNDLE_ID:-$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)}"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$APP_ID.widgets</string>
  <key>CFBundleName</key><string>$APP_NAME Widgets</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>EncoreWidgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none --options runtime --entitlements Resources/EncoreWidgets.entitlements "$APPEX"

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
