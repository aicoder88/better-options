#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT_DIR/dist/BetterOptions.app"
APP_DST="/Applications/BetterOptions.app"
PLIST_PATH="/Library/LaunchAgents/com.dgcode88.betteroptions.plist"

if [ ! -d "$APP_SRC" ]; then
    echo "App bundle not found. Run ./scripts/build_app_bundle.sh first."
    exit 1
fi

echo "Installing BetterOptions.app to /Applications..."
sudo cp -R "$APP_SRC" "$APP_DST"

echo "Creating launch agent for all users..."
sudo tee "$PLIST_PATH" > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dgcode88.betteroptions</string>
    <key>Program</key>
    <string>/Applications/BetterOptions.app/Contents/MacOS/BetterOptions</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

sudo launchctl load "$PLIST_PATH"

echo "Done. BetterOptions will start automatically at login for all users."
