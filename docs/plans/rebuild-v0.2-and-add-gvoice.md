# Rebuild what 0.2 had, then put GVoice on the side button

Written 2026-08-13. Nothing here runs until Mark says go.

## Why this plan exists

The app running in the menu bar is **0.2**, built 2026-03-27. **Its source is gone** —
written after the 2026-03-23 backup, never committed, folder deleted before the
2026-06-08 backup. Searched on 2026-08-13 and found nothing: the whole Mac, Trash,
iCloud, both Google Drive accounts, drives 970 and pt2, every Time Machine backup
covering the window, and both GitHub accounts (`aicoder88/better-options` has 6 commits
ending 2026-03-20; `Dgcode88/better-options` is older still).

This repo is **0.1 plus a GVoice change** (commit `8191dd1`). Installing it as-is would
be a downgrade — GVoice in, four features out. This plan closes that gap instead.

**Already done, do not redo:** the 0.2 binary is preserved on GitHub at branch
`artifact/v0.2-binary` under `artifacts/`, verified byte-identical (733,216 bytes).

**The five files 0.2 added on top of 0.1** — recovered from a `git status` inside a
2026-04-26 session record, which is the only trace left of them:
`DeviceRegistry.swift`, `SettingsStore.swift`, `SettingsView.swift`,
`SettingsWindowController.swift`, `SystemActionSender.swift`.

**What they did**, read out of the binary and its settings file (full write-up in
`docs/recovered-v0.2-features.md`): a settings window where any trigger points at any
action; a menu bar icon instead of the word "Options"; the actions Toggle Mute,
Brightness Up/Down, Play/Pause, Previous Track and Default (Pass Through); and a
per-device binding list saved to
`~/Library/Application Support/BetterOptions/settings.json`.

**This is a rewrite, not a recovery.** The behaviour is known; the code will be new.

**Dependencies:** Step 1 gates 2, 3 and 5 — they all read the model it defines. Steps
2, 3, 4 and 5 each touch `Sources/` and `AppCoordinator.swift`; run them one at a time,
never side by side. Step 6 needs 1–5 finished. Step 7 needs 6 and is GATED.

**Two things that will bite:**
- `scripts/install.sh` is the only install path that backs up the running app first
  (added in commit `116900a`). The `install.sh` at the repo root is an unrelated script
  for Claude settings — do not run it.
- Every reinstall changes the code signature, so macOS revokes Accessibility and Input
  Monitoring. Re-grant both or the buttons silently do nothing.

## Steps

### 1. The data model: settings and devices [opus/high]
Write `Sources/SettingsStore.swift` and `Sources/DeviceRegistry.swift`. The store must
read and write the **existing** `~/Library/Application Support/BetterOptions/settings.json`
without changing its shape: a list of bindings each holding `deviceID`, `trigger` and
`action`, plus a top-level `enabled` flag and `version` number. Mark's live file
(written 2026-03-25, device `mx-master-3`) must keep working untouched. `DeviceRegistry`
tracks connected devices by id and exposes a display name for the menu.
-> verify: `swift build` clean, and a unit check that loads Mark's real settings file,
writes it back, and produces a byte-identical file.

### 2. The extra actions [sonnet/medium]
Write `Sources/SystemActionSender.swift` covering Toggle Mute, Brightness Up, Brightness
Down, Play/Pause and Previous Track, alongside the volume handling that already exists in
`MediaKeySender.swift`. Add `Default (Pass Through)` as a real option meaning "leave this
trigger alone".
-> verify: each action fires on the Mac when invoked directly — mute toggles, brightness
moves, playback responds; pass-through leaves the button behaving as the system default.

### 3. The settings window [opus/high]
Write `Sources/SettingsView.swift` and `Sources/SettingsWindowController.swift` in
SwiftUI. Every trigger (Thumb Wheel Left, Thumb Wheel Right, Side Button) can be pointed
at any action from step 2, plus GVoice PTT. Changes save through `SettingsStore`
immediately. Include Reset to Defaults.
-> verify: the built app opens Settings from the menu; changing a binding rewrites
`settings.json`; the change survives quitting and relaunching the app.

### 4. Menu bar icon and menu entries [sonnet/low]
Replace the text title with the `computermouse` SF Symbol using a symbol configuration.
Menu entries 0.2 had: Remapping Enabled, Settings…, Reset to Defaults, Devices: <name>,
No devices detected, Accessibility granted / Accessibility permission required.
-> verify: the menu bar shows an icon, not the word "Options", and every entry above
appears with the right state.

### 5. GVoice as a selectable action [sonnet/medium]
`Sources/GVoiceIntegration.swift` already exists from commit `8191dd1`, where the side
button is hardcoded to it. Make it one action among the others instead, selectable per
trigger. Default Mark's side button to GVoice PTT so the upgrade needs no setup.
-> verify: holding the side button starts and stops GVoice dictation; `grep -ri wispr
Sources/` returns nothing; the same action can be assigned to a different trigger and
works there.

### 6. Version 0.3 and build [sonnet/low]
Set `CFBundleShortVersionString` to `0.3` and `CFBundleVersion` to `3` in
`AppBundle/Info.plist`, so no future session mistakes the installed app for an older one
again. Build with `./scripts/build_app_bundle.sh`.
-> verify: `defaults read <built app>/Contents/Info.plist CFBundleShortVersionString`
prints `0.3`, and the app launches from the build folder.

### 7. GATED — install it [sonnet/low] GATED
Needs Mark's explicit go and his admin password; `/Applications` refuses writes without
one. Run `./scripts/install.sh` — it saves the installed copy to
`~/.app-backups/BetterOptions/<timestamp>/` first. Confirm that backup folder holds a
real app bundle **before** trusting the install. Then re-grant Accessibility and Input
Monitoring in System Settings → Privacy & Security.
-> verify: `defaults read /Applications/BetterOptions.app/Contents/Info.plist
CFBundleShortVersionString` prints `0.3`; `pgrep -f /Applications/BetterOptions.app`
returns a process; Mark confirms thumb wheel volume, the extra actions, and GVoice on
the side button all work.

Close: `/tier /Users/macmini/dev/better-options/docs/plans/rebuild-v0.2-and-add-gvoice.md`
