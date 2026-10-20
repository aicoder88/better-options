#!/bin/sh
set -eu

# Checks that a side button's press and release always reach the apps together,
# so the Mac can never be left thinking the button is still held.

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/side-button-check"

mkdir -p "$BUILD_DIR"
swiftc -O \
    -o "$BUILD_DIR/side-button-check" \
    "$ROOT_DIR/Sources/SideButtonPairing.swift" \
    "$ROOT_DIR/scripts/side-button-check/main.swift"

"$BUILD_DIR/side-button-check"
