#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/BetterOptions.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT_DIR"
# A build that would leave a mouse button stuck down never gets made.
"$ROOT_DIR/scripts/check-side-button.sh"
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/.build/debug/BetterOptions" "$MACOS_DIR/BetterOptions"
chmod +x "$MACOS_DIR/BetterOptions"
# Sign with the machine's own long-lived signing identity, not ad-hoc.
#
# An ad-hoc signature changes every single build, and macOS ties Accessibility
# and Input Monitoring to the exact signature it approved. A new build was
# therefore a stranger, and the mouse went dead until both switches were
# granted again. This happened on 2026-09-10 and cost the volume wheel two days.
# A fixed identity keeps the same signature across builds, so the grants stick.
SIGNING_IDENTITY="${BETTER_OPTIONS_SIGNING_IDENTITY:-91CEC2476265A71B2046EE5A18CDAE87528AE625}"

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier com.dgcode88.betteroptions "$APP_DIR"
else
    echo "WARNING: signing identity $SIGNING_IDENTITY not found; falling back to ad-hoc." >&2
    echo "         macOS will drop Accessibility and Input Monitoring for this build." >&2
    codesign --force --deep --sign - --identifier com.dgcode88.betteroptions "$APP_DIR"
fi

echo "$APP_DIR"
