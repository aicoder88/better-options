#!/bin/sh
set -eu

# Talks to a stand-in GVoice over a real socket and checks the whole
# conversation: hello, the heartbeat, a recording started when the button goes
# down, ended when it comes up, and dictation withdrawn the moment GVoice hangs
# up. Nothing here touches the real dictation app or the real microphone.
#
# Better Options only reaches for the socket while GVoice is actually running,
# so this check needs GVoice open. With it closed the check says so and stops
# rather than pretending to have passed.

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/gvoice-socket-check"

if ! pgrep -f "/Applications/GVoice.app/Contents/MacOS/GVoice" >/dev/null 2>&1; then
    echo "SKIPPED: GVoice is not running, so there is nothing for the companion to reach for."
    exit 0
fi

mkdir -p "$BUILD_DIR"
swiftc -O \
    -o "$BUILD_DIR/gvoice-socket-check" \
    "$ROOT_DIR/Sources/GVoiceIntegration.swift" \
    "$ROOT_DIR/scripts/gvoice-socket-check/main.swift"

SOCKET_DIR="$(mktemp -d /tmp/bo-gvoice-check.XXXXXX)"
trap 'rm -rf "$SOCKET_DIR"' EXIT

BETTEROPTIONS_GVOICE_SOCKET="$SOCKET_DIR/gvoice.sock" "$BUILD_DIR/gvoice-socket-check"
