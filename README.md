# Better Options

Better Options is a small macOS menu bar app for remapping an `MX Master 3` / `MX Master 3 Mac`:

- Thumb wheel left/right -> system volume down/up
- Back side button -> Wispr Flow push-to-talk

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

## Requirements

- macOS 13+
- **Accessibility** permission for `Better Options` (the app prompts for this automatically on launch)
- **Input Monitoring** permission (required for reading HID events from the mouse)
- Wispr Flow installed if you want the push-to-talk remap

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
- The app checks `~/Library/Application Support/Wispr Flow/config.json` and expects shortcut `4099` to be bound to `ptt`.
- If Wispr Flow is not running, the Back button falls through to normal behavior.
