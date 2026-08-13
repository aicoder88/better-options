#!/bin/sh
set -eu

# Checks the settings window: that it builds and lays out, that picking a
# different action writes the settings file right away, and that the change is
# still there next time. Reads nothing from and writes nothing to the real
# settings file — every write goes to a throwaway copy.

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/settings-window-check"

mkdir -p "$BUILD_DIR"
swiftc -O \
    -o "$BUILD_DIR/settings-window-check" \
    "$ROOT_DIR/Sources/SettingsStore.swift" \
    "$ROOT_DIR/Sources/DeviceRegistry.swift" \
    "$ROOT_DIR/Sources/SettingsView.swift" \
    "$ROOT_DIR/Sources/SettingsWindowController.swift" \
    "$ROOT_DIR/scripts/settings-window-check/main.swift"

"$BUILD_DIR/settings-window-check"
