# Better Options

Better Options is a small macOS menu bar app for remapping an `MX Master 3` / `MX Master 3 Mac`:

- Thumb wheel left/right -> system volume down/up
- Back side button -> GVoice hold-to-talk dictation

## Run

```bash
swift build
.build/debug/BetterOptions
```

Or:

```bash
swift run
```

To build a normal macOS app bundle that is easier to grant in Accessibility:

```bash
./scripts/build_app_bundle.sh
open dist/BetterOptions.app
```

## Install

```bash
./scripts/build_app_bundle.sh
./scripts/install.sh
```

This installs `BetterOptions.app` to `/Applications` and registers a launch agent so it starts at login.

> **Note:** Builds are signed with a fixed local identity ("Better Options Local
> Signing", created 2026-09-12), so **Accessibility** and **Input Monitoring** now
> survive a reinstall. Before that, every build was ad-hoc signed, got a new
> signature, and macOS silently revoked both permissions — on 2026-09-10 that
> killed the thumb wheel for two days with the switches still showing as on.
>
> If `security find-identity -v -p codesigning` no longer lists that identity,
> the build script falls back to ad-hoc and prints a warning; then the
> permissions do have to be granted again, as described under Troubleshooting.

## Requirements

- macOS 13+
- **Accessibility** permission for `Better Options` (the app prompts for this automatically on launch)
- **Input Monitoring** permission (required for reading HID events from the mouse)
- GVoice installed if you want the hold-to-talk remap

## Troubleshooting permissions

Rebuilding the app changes its ad-hoc code signature, which invalidates previously granted macOS permissions. If the app stops receiving mouse events after a rebuild:

```bash
# Reset stale TCC entries
tccutil reset Accessibility com.dgcode88.betteroptions
tccutil reset ListenEvent com.dgcode88.betteroptions

# Relaunch and re-grant both permissions when prompted
pkill -x BetterOptions
open dist/BetterOptions.app
```

Then go to **System Settings → Privacy & Security** and re-enable both **Accessibility** and **Input Monitoring** for Better Options.

## Notes

- Remapping only activates when a matching MX Master 3 device is connected.
- Holding the Back button asks GVoice to record, over a local socket in GVoice's own folder (`~/Library/Application Support/GVoice/control/gvoice.sock`). No keys are faked any more: Better Options says "start" when the button goes down and "stop" when it comes up, and GVoice ends the recording by itself if Better Options stops answering. Set `BETTEROPTIONS_GVOICE_SOCKET` to talk to a GVoice running on its own data folder instead.
- Better Options swallows the raw Back button so holding it doesn't also fire browser-back while you dictate.
- If GVoice is not running, or is a build with no socket to talk on, the Back button falls through to normal behavior and the menu says which it is.
