#!/usr/bin/env bash
# Builds Player.app into ./build: the Swift app, plus the Now Playing helper
# (an ObjC library loaded by /usr/bin/perl, see Helper/).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Player.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Player" "$APP/Contents/MacOS/Player"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Helper/helper.pl "$APP/Contents/Resources/helper.pl"

# App icon: compile the layered Icon Composer document (regenerate with scripts/make-icon.swift).
# Absolute paths: actool hands off to a shared agent process that resolves relative paths
# against its own working directory (possibly another project's).
xcrun actool "$PWD/Resources/AppIcon.icon" \
  --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PWD/build/assetcatalog_info.plist" \
  --errors --warnings --output-format human-readable-text | grep -vE "^/\* com.apple.actool.compilation-results \*/|\.(car|icns|plist)$|^$" || true

# Universal, because /usr/bin/perl is universal and may run as either arch.
clang -dynamiclib -fobjc-arc -O2 -Wall -Wextra \
  -mmacosx-version-min=26.0 -arch arm64 -arch x86_64 \
  -framework Foundation \
  Helper/MediaRemoteHelper.m \
  -o "$APP/Contents/Resources/MediaRemoteHelper.dylib"

# Sign with a development certificate when there is one: macOS ties privacy permissions
# (audio recording, controlling other apps) to the signature, and an ad-hoc signature
# changes on every build, which would re-prompt each time. Override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/Resources/MediaRemoteHelper.dylib"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "Built $APP (signed: $IDENTITY)"
