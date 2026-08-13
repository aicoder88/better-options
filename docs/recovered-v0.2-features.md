# What version 0.2 had that this repo doesn't

On 2026-08-13 the copy installed in `/Applications` turned out to be version 0.2,
while this repo is still 0.1. Its source was never pushed here and isn't anywhere
on the Mac mini. The installed app was overwritten and then recovered from that
morning's automatic snapshot; the rescued copy is kept at:

`/Users/macmini/.app-backups/BetterOptions/2026-08-13-recovered-v0.2/BetterOptions.app`

Everything below was read out of that binary (readable text plus its saved
settings file), so it lists what 0.2 *had*, not how it was written.

## Saved settings

`/Users/macmini/Library/Application Support/BetterOptions/settings.json` — written
by 0.2, still on disk, and the clearest record of the design:

- A list of bindings, each one `deviceID` + `trigger` + `action`.
- Device in use: `mx-master-3`.
- Live bindings: thumb wheel left -> volume up, thumb wheel right -> volume down,
  side button -> Wispr push-to-talk.
- Top-level `enabled` flag and a `version` number.

## Menu bar

- An icon instead of the word "Options" — the system `computermouse` symbol,
  sized through a symbol configuration.
- Menu entries: `Remapping Enabled`, `Settings...`, `Reset to Defaults`,
  `Devices: <name>`, `No devices detected`, `Accessibility granted` /
  `Accessibility permission required`, and the Wispr status lines.

## Settings window

Built with SwiftUI: `SettingsView`, `SettingsViewModel`, `SettingsStore`,
`SettingsWindowController`. It let each trigger be pointed at any action.

- Triggers offered: `Thumb Wheel Left`, `Thumb Wheel Right`, `Side Button`.
- Actions offered: `Volume Up`, `Volume Down`, `Toggle Mute`, `Brightness Up`,
  `Brightness Down`, `Play / Pause`, `Previous Track`, `Wispr PTT`, and
  `Default (Pass Through)` to leave a trigger alone.

## What 0.1 in this repo does instead

Everything is fixed in code: thumb wheel is always volume, the side button is
always push-to-talk, there is no settings window, no brightness or playback
actions, no per-device list, and the menu bar shows text rather than an icon.
