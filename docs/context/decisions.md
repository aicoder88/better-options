# Decisions

## 2026-09-12 — Builds are signed with a fixed local identity, not ad-hoc

Every build used to be signed ad-hoc (`codesign --sign -`), which gives the app a
new signature each time. macOS pins Accessibility and Input Monitoring to the
exact signature it approved, so each reinstall silently cut the app off from the
mouse while both switches still looked on. That is what stopped the thumb wheel
working on 2026-09-10.

A self-signed code signing certificate, "Better Options Local Signing", now lives
in the login keychain and is trusted for code signing in the machine's admin
trust domain. `scripts/build_app_bundle.sh` signs with it by hash, and warns and
falls back to ad-hoc if it is missing. The designated requirement is now
`identifier "com.dgcode88.betteroptions" and certificate root = H"91cec2..."`,
which stays the same across builds.

Reverse if: the certificate is lost, or the app ever needs a real Apple Developer
identity for distribution. Then generate a new identity, put its hash in
`BETTER_OPTIONS_SIGNING_IDENTITY`, and grant both permissions one more time.

## 2026-10-04: Side button drives Handy, not GVoice

Drago moved dictation from GVoice to Handy and GVoice was removed from the Mac.
The side button now sends Handy SIGUSR2 on press and again on release, the
signal Handy itself documents for `--toggle-transcription`. GVoice's socket
connector and its check were deleted. Saved bindings named `gvoicePTT` or
`wisprPTT` still mean dictation, because push-to-talk matches any name ending in
`PTT`. The settings file on this Mac was switched to `handyPTT`; its old copy is
`settings.json.bak-before-handy-2026-10-04` beside it.

Reverse if: Handy drops the signal, or a missed release leaves it recording
often. Then bind the button to Handy's keyboard shortcut instead.

## 2026-10-19: Thumb button dictates, back button switches apps

The thumb (gesture) button now drives Handy hold-to-talk, taken over through
HID++ (feature 0x1B04, control 0xC3) so it reports press and release. The back
button now sends one Cmd+Tab. Handy's own shortcut is Option+Space, never a
mouse button: Handy listening to the same button as Better Options made the
two flip recording on and off against each other.

Reverse if: the thumb button stops reporting holds after a mouse or macOS
update. Then put dictation back on the back button.
