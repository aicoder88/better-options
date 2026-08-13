#!/bin/sh
set -eu

# Checks that reading and writing the settings file leaves it byte for byte the
# same, so the file the 0.2 build left behind keeps working. Reads the real
# settings file; only ever writes to throwaway copies.

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/settings-check"

mkdir -p "$BUILD_DIR"
swiftc -O \
    -o "$BUILD_DIR/settings-check" \
    "$ROOT_DIR/Sources/SettingsStore.swift" \
    "$ROOT_DIR/Sources/DeviceRegistry.swift" \
    "$ROOT_DIR/scripts/settings-check/main.swift"

"$BUILD_DIR/settings-check"
