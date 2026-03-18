#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/BetterOptions.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/.build/debug/BetterOptions" "$MACOS_DIR/BetterOptions"
chmod +x "$MACOS_DIR/BetterOptions"
codesign --force --deep --sign - --identifier com.dgcode88.betteroptions "$APP_DIR"

echo "$APP_DIR"
