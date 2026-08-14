# Rebuild run report — 2026-08-13

> **Second pass, 2026-08-14: backups taken, and keyboard support restored.**
> Read "Backups" and "Second pass" at the bottom first — the first pass shipped a
> build that was missing a whole device.


Plan run: `/Users/macmini/dev/better-options/docs/plans/rebuild-v0.2-and-add-gvoice.md`
Steps 1–6 ran. Step 7 (install to `/Applications`) was skipped — gated, needs Mark's go
and his admin password.

Branch during the run: `artifact/v0.2-binary`. Nothing committed, nothing pushed,
nothing installed. The old app in `/Applications` is untouched and still running.

## Step results

### 1. Data model — DONE, verify passed [opus/high]
New: `Sources/SettingsStore.swift`, `Sources/DeviceRegistry.swift`,
`scripts/settings-check/main.swift`, `scripts/check-settings.sh`.

Reads and writes the existing `~/Library/Application Support/BetterOptions/settings.json`
in the 0.2 shape: bindings of `deviceID` / `trigger` / `action`, top-level `enabled` and
`version`. `[.prettyPrinted, .sortedKeys]`, no trailing newline.

Verify: `swift build` clean. `./scripts/check-settings.sh` — 34 checks, all pass. Both a
0.2 fixture and a **copy** of Mark's real file round-trip byte-identical (491 bytes).
Mark's live file was read only — md5 `bbc0dda9d66a12e464eef8526f0139ce` and mtime
`Mar 25 00:40` unchanged.

Two design calls that matter downstream:
- `Action` and `Trigger` are `RawRepresentable` structs, not enums, so the unknown name
  in Mark's live file (`wisprPTT`) survives a load/save untouched. That is what makes the
  byte-identical round trip work and keeps `grep -ri wispr Sources/` at zero hits.
- The binding type is `TriggerBinding`, not `Binding`, so it does not shadow SwiftUI's.

Could not check: `swift test` is impossible on this Mac — only Command Line Tools are
installed, no Xcode, so there is no `XCTest` module. The unit check is a standalone
compiled program instead of a SwiftPM test target.

### 2. Extra actions — DONE, verify partial [sonnet/medium]
New: `Sources/SystemActionSender.swift`. Covers Toggle Mute, Brightness Up, Brightness
Down, Play/Pause, Previous Track, and routes Volume Up/Down through the existing
`MediaKeySender`. `Default (Pass Through)` and `GVoice PTT` are explicit no-ops at this
layer — pass-through means the caller skips dispatch; GVoice's hold chord stays owned by
`GVoiceIntegration`.

Edited: `Sources/MediaKeySender.swift` — `sendMediaKey` widened from `private` to
internal so `SystemActionSender` reuses the same event-posting code instead of
duplicating it.

Verify: `swift build` clean. Fired for real on this Mac via a throwaway binary — Volume
Down moved system volume 100→94, Volume Up back to 100, Toggle Mute flipped
false→true→false, all confirmed by reading real system state with `osascript`.

**Unverified:** Brightness Up/Down and Play/Pause/Previous Track posted their events with
no errors, but this Mac mini has no brightness-adjustable built-in display and no media
player was running. Same posting mechanism as the working volume path, so it should work
on Mark's setup — but "the event posted cleanly" is all that was proven.

### 3. Settings window — DONE, verify passed on the real app [opus/high]
New: `Sources/SettingsView.swift`, `Sources/SettingsWindowController.swift`,
`scripts/check-settings-window.sh`, `scripts/settings-window-check/main.swift`.

One row per control (Thumb Wheel Left, Thumb Wheel Right, Side Button), each pointing at
any of nine actions including GVoice PTT and Default (Pass Through). Mouse picker lists
connected mice first, saved-but-unplugged ones as "(not connected)". Reset to Defaults
with a confirmation. No Save button — every pick writes through `SettingsStore` at once.

Edited: `Sources/AppCoordinator.swift` (loads the store at launch, adds `Settings…`,
keeps the connected-mouse list current), `Sources/SettingsStore.swift`
(`defaultDeviceID` no longer private).

**Bug found and fixed** in `Sources/HIDDeviceMonitor.swift`: the live mouse reports its
name as "MX Master 3 Mac", so step 1's id rule produced `mx-master-3-mac`, which matches
nothing in the saved file — the window showed all three controls unbound even though the
file had bindings. Added `activeDeviceModel`, which returns the matched model
"MX Master 3" → `mx-master-3`. Step 5 needed this too, or the remap would have fired
nothing on Mark's actual mouse.

Verify: built the bundle, launched it, opened Settings from the menu — window "Better
Options" (460x334), Mouse = MX Master 3, Mark's real bindings shown (Volume Up, Volume
Down, `wisprPTT` — the unknown name stays selectable instead of being silently dropped).
Changed Thumb Wheel Left to Play / Pause: `settings.json` changed on disk at once
(`"action" : "playPause"`). Quit, relaunched, reopened: still Play / Pause. Reset to
Defaults asked first, then wrote volumeUp / volumeDown / gvoicePTT. `swift build` clean,
both check scripts pass, `grep -ri wispr Sources/` returns nothing.

Safety: Mark's live settings file was backed up before testing and restored byte-exact
after (sha256 `d14e5f41…` before and after). The test copy was quit. Only the installed
0.2 (pid 1139) still runs.

Not checked at this step: whether a chosen action fires from the mouse — that wiring is
step 5. The test copy never got Accessibility or Input Monitoring rights (new signature),
so its event tap never installed; that is why the icon read "Options !" during the test.

### 4. Menu bar icon and entries — DONE [sonnet/low]
Edited: `Sources/AppCoordinator.swift`. Menu bar shows the mouse-shaped `computermouse`
symbol, no more "Options" text. Menu has: "Remapping Enabled" (checkmark), "Settings…",
"Reset to Defaults", the device line, and the Accessibility state line.

### 5. GVoice as a selectable action — DONE [sonnet/medium]
Edited: `Sources/AppCoordinator.swift`, `Sources/GVoiceIntegration.swift`,
`Sources/EventTapController.swift`. GVoice is now one action among the others, chosen per
trigger from the real settings file, instead of hardcoded to the side button. Side button
still defaults to GVoice with zero setup, including when reading Mark's live file that
still names the old dictation app in that slot.

`grep -ri wispr Sources/` — zero hits across all ten source files (re-checked after the
run).

### 6. Version 0.3 and build — DONE, verify passed [sonnet/low]
Edited: `AppBundle/Info.plist` — `CFBundleShortVersionString` `0.3`, `CFBundleVersion` `3`.
Built with `./scripts/build_app_bundle.sh` to
`/Users/macmini/dev/better-options/dist/BetterOptions.app`.

Verify: `defaults read dist/BetterOptions.app/Contents/Info.plist
CFBundleShortVersionString` prints `0.3`; the app launched from the build folder
(pid 79813 at the time).

### 7. Install — NOT RUN, GATED
Needs Mark's explicit go and his admin password. When approved:
`./scripts/install.sh` (the one in `scripts/`, NOT the repo-root `install.sh`, which is an
unrelated Claude settings script). It saves the installed copy to
`~/.app-backups/BetterOptions/<timestamp>/` first — confirm that folder holds a real app
bundle before trusting the install. Then re-grant Accessibility and Input Monitoring in
System Settings → Privacy & Security, because every reinstall changes the code signature
and macOS revokes both.

## Open decision — which branch this work belongs on

The checkout sits on `artifact/v0.2-binary` (= `main` plus the preserved 0.2 binary).
Committing the rebuild there would muddy the artifact branch; switching to `main` would
remove `artifacts/BetterOptions-v0.2.app` from the working tree. Everything is uncommitted
and safe on disk right now:

Modified: `AppBundle/Info.plist`, `Sources/AppCoordinator.swift`,
`Sources/EventTapController.swift`, `Sources/GVoiceIntegration.swift`,
`Sources/HIDDeviceMonitor.swift`, `Sources/MediaKeySender.swift`, and the built bundle
under `dist/`.

New: `Sources/DeviceRegistry.swift`, `Sources/SettingsStore.swift`,
`Sources/SettingsView.swift`, `Sources/SettingsWindowController.swift`,
`Sources/SystemActionSender.swift`, `docs/plans/`, `scripts/check-settings.sh`,
`scripts/check-settings-window.sh`, `scripts/settings-check/`,
`scripts/settings-window-check/`.

## Still unproven until the new app is installed and granted permissions

- Brightness Up/Down and Play/Pause/Previous Track producing a visible effect.
- Any action firing from an actual mouse press — the test copy never held Accessibility
  or Input Monitoring rights, so its event tap never installed.

---

# Backups — 2026-08-14

Everything below lives in `/Users/macmini/.app-backups/BetterOptions/2026-08-13-234944-pre-rebuild/`.
Copies only; nothing was moved or deleted.

- `BetterOptions.app-installed-v0.2/` — the app running in the menu bar right now,
  copied straight out of `/Applications`. Verified identical to the original, byte for
  byte: sha256 `9db81ed0992a5027d3fbd6d71c980e56e07cdc5cc10f3b9aa30fff4624a97ba4` on both.
- `source-worktree/` — the whole working folder as it stood before this second pass,
  rebuild work included, minus build junk.
- `source-main-committed/` — a clean copy of the last committed source of the old app
  (`main` = 0.1 plus the GVoice change), straight out of git.

Two older backups were already there and were left alone:
`2026-08-13-recovered-v0.2/` (the rescued 0.2 bundle) and `2026-08-13-replaced-v0.1/`.

The 0.2 binary also stays preserved in the repo at `artifacts/BetterOptions-v0.2.app`
and on the `artifact/v0.2-binary` branch.

# Second pass — what the first rebuild had missed

The plan was written from `docs/recovered-v0.2-features.md`, which listed the mouse
only. Reading the preserved 0.2 binary directly turned up more, and reading the running
0.2's own menu through the accessibility interface confirmed it:

**0.2's live menu reads `Devices: MX Keys S, MX Master 3`.** It handled the keyboard as
well as the mouse. The first rebuild handled the mouse only, so installing it would have
silently dropped a device.

Everything found missing, and now restored:

| What 0.2 had | State after the first pass | Now |
| --- | --- | --- |
| Keyboard as a second remappable device (`KnownDevice`, `DeviceType`, `consumerKey` trigger, `keyboardConsumerUsages`) | absent | restored |
| Toggle line that reads `Disable Remapping` while on | fixed text `Remapping Enabled` | matches 0.2 |
| `Input Monitoring` permission state in the menu | absent | restored |
| Swallowing the Mac's own copy of a remapped key (`shouldConsumeMediaKey`) | absent | restored |

## How the keyboard works now

- **`Sources/DeviceRegistry.swift`** — new `DeviceType` (mouse / keyboard) and
  `KnownDevice`, a two-row table: `MX Master 3` (mouse) and `MX Keys S` (keyboard).
  Matching is on a lower-cased prefix, because the Mac reports longer, differently-cased
  names — `MX Master 3 Mac` and `MX KEYS S MAC`. Case-sensitive matching would have
  missed the keyboard entirely, the same way it missed the mouse before.
- **`Sources/SettingsStore.swift`** — `Trigger` now carries an optional HID `usage`, so
  one key on the function row can be told from another. It saves inside the same object
  the old format already used: `{"consumerKey": {"usage": 233}}`. A control with no
  usage still writes the empty object 0.2 wrote, which is what keeps the existing file
  round-tripping byte for byte. New `ConsumerKey` enum names the eight function-row keys
  and translates between the keyboard's numbering and macOS's own.
- **`Sources/HIDDeviceMonitor.swift`** — tracks each device's type, reports function-row
  presses through a new `onConsumerKeyEvent`, and can say whether the keyboard just sent
  a given key.
- **`Sources/EventTapController.swift`** — watches system-defined events (the media
  keys) and swallows one only when that key has been pointed somewhere else *and* the
  keyboard itself just sent it. Otherwise the key does what it is printed with.
- **`Sources/SettingsView.swift`** — the picker is now "Device", not "Mouse", and the
  rows below it change with the device: the wheel and side button for the mouse, the
  eight function-row keys for the keyboard. A known device that is unplugged still gets
  a row, so the keyboard can be set up before it is next connected.
- **`Sources/AppCoordinator.swift`** — routes keyboard presses to whatever they are
  bound to, keeps the device list in step with what is plugged in, adds the Input
  Monitoring line, and matches 0.2's toggle wording.

**Every function-row key defaults to Default (Pass Through)** — untouched, the keyboard
behaves exactly as before. Nothing is swallowed until a key is deliberately pointed
somewhere else.

## A bug the checks caught

Pointing one key at a new action moved *every* key on the row. Cause: a Swift type that
declares `RawRepresentable` gets a free equality test that only ever compares the name —
so every `consumerKey` trigger counted as the same trigger, whatever key it held.
`Trigger` now compares the name and the key number. Written out by hand in
`Sources/SettingsStore.swift` with a comment saying why, because the compiler will
happily hand back the wrong one again.

A second, smaller fix from a self-review: the recent-key check read the key and its
timestamp in two separate locks, so a press on another key could land between them. Both
are now read together.

## Verified on the real hardware

- `swift build` clean.
- `./scripts/check-settings.sh` — all pass, including the byte-identical round trip of a
  copy of the live settings file.
- `./scripts/check-settings-window.sh` — all pass, now covering the keyboard: the
  function row shows up, an untouched key is left alone, pointing one key somewhere else
  survives a restart and moves neither the key beside it nor anything on the mouse.
- Device detection, probed against the hardware plugged in right now: the app sees
  `MX Master 3 [mouse]` and `MX Keys S [keyboard]`.
- The built app was launched and its menu read live:
  `Devices: MX Master 3, MX Keys S` / `Disable Remapping` / `Reset to Defaults` /
  `Accessibility permission required` / `Input Monitoring permission required` /
  `GVoice: ready` / `Show Volume HUD` / `Settings…` / `Open Accessibility Settings` /
  `Quit Better Options`. The two permission lines are expected — a freshly built copy
  has neither until it is installed and granted.
- The settings window was driven for real: it opened on `MX Master 3` showing Mark's
  saved bindings (including the old dictation name on the side button, preserved rather
  than dropped); switching the picker to `MX Keys S` listed all eight keys as Default
  (Pass Through); pointing Brightness Down Key at Play / Pause wrote
  `mx-keys-s / consumerKey usage 112 -> playPause` and left all three mouse bindings
  untouched.
- Mark's live settings file was backed up before that test and restored byte-exact
  afterwards (sha256 `d14e5f41…` before and after). Both test copies were quit. Only the
  installed 0.2 (pid 1139) is still running.

## Still unproven until it is installed and granted permissions

- An actual press of a remapped function-row key doing the new thing, and the Mac's own
  copy of that press being swallowed. The test copy had neither Accessibility nor Input
  Monitoring, so its event tap never installed — that is unavoidable until the real
  install.
- Brightness and playback producing a visible effect: this Mac mini has no
  brightness-adjustable built-in display and no media player was running.

## Note for whoever installs it

`scripts/install.sh` is the one to run — NOT the `install.sh` at the repo root, which is
an unrelated Claude settings script. After installing, grant **both** Accessibility and
Input Monitoring. Every reinstall changes the code signature and macOS revokes both; the
keyboard and mouse are invisible to the app without Input Monitoring, and the remap does
nothing without Accessibility.

---

# Third pass — the full comparison, done properly

The keyboard was found by skimming a filtered list of readable text out of the 0.2 app.
That is luck, not a method, so this pass did the exhaustive version: every readable
string in 0.2, minus every readable string in the new build, reviewed one by one.

**139 strings were in 0.2 and not in the rebuild. 92 of them were readable.** Reviewing
all 92 turned up five more real gaps, one of which would have quietly broken a saved
setup.

## 1. The names in the saved file were wrong — the serious one

The rebuild invented its own names for the actions. 0.2's real names, read out of the
0.2 app's own type information:

| Action | 0.2 wrote | The rebuild wrote |
| --- | --- | --- |
| Default (Pass Through) | `passthrough` | `passThrough` |
| Toggle Mute | `volumeMute` | `toggleMute` |
| Play / Pause | `mediaPlayPause` | `playPause` |
| Previous Track | `mediaPrevious` | `previousTrack` |
| Next Track | `mediaNext` | *(action did not exist)* |
| Volume Up / Down, Brightness Up / Down | `volumeUp` etc. | same |

Mark's own file happens to use only Volume Up, Volume Down and the dictation button, so
it survived by luck. Any *other* binding saved by 0.2 would have loaded as an
unrecognised name — and the rebuild's rule for an unrecognised name was **"treat it as
push-to-talk"**. So a mute key saved by 0.2 would have started dictation instead of
muting.

Both halves are fixed. The names now match 0.2 exactly, and the fallback is no longer
"anything unknown means dictation" — it is "a name ending in PTT means dictation", which
still covers the old dictation app's name without that app appearing anywhere in this
build. An unknown name that is not push-to-talk now does nothing, rather than doing
something surprising.

`scripts/settings-check/main.swift` grew a section that pins all nine names and loads a
full 0.2-era file using every one of them.

## 2. Next Track was missing entirely

0.2 offered ten actions. The rebuild offered nine — `Next Track` (`mediaNext`, system key
17) was absent from both the action list and the sender. Restored.

## 3. The menu bar icon was the wrong picture

This is the one Mark asked about by name, and the rebuild had it wrong in two ways.

**It is not a mouse. It is a keyboard with a mouse beside it, overlapping.** 0.2 drew
both the `keyboard` and the `computermouse` symbols into a single image — which is why
the 0.2 app contains image-drawing calls at all, something a single symbol would never
need. The rebuild drew only the mouse.

**And the slot was the wrong width.** 0.2 used a fixed square slot, 24 points wide.
The rebuild let the slot size itself, which came out 36 points and would have shoved
every icon to its left along the menu bar.

Confirmed by measuring both apps' menu bar items live, side by side, and by photographing
both icons: 0.2 at 24 points wide, the rebuild at 36. After the fix, both are 24, and the
picture is the same mark — keyboard left, mouse overlapping at the right, slightly taller.

One thing that could not be settled: whether 0.2's icon was fixed, or changed with which
devices were plugged in. Both devices are connected on this Mac, so there was no way to
see it in another state without unplugging Mark's own keyboard. The rebuild draws it
fixed, which matches what is on screen today in every state.

## 4. Menu wording

- `Settings...` — three full stops, as 0.2 had. The rebuild used the single-character
  ellipsis, which is not the same text.
- `Grant: Accessibility, Input Monitoring` — 0.2 put both missing permissions on one
  line behind a `Grant: ` prefix. The rebuild had invented a second, separate menu line
  for Input Monitoring. Now one line, 0.2's wording, and picking it asks for whichever
  permission is actually missing.
- The device line carries 0.2's tooltips again: `Device connected` /
  `No matched device detected`.

## 5. What is legitimately still different

After the fixes, **no user-visible text from 0.2 is missing from the new build.**
What remains in the comparison is:

- **The old dictation app** — its name, its settings file path, its bundle id, its five
  status lines, and its dispatch plumbing (`PTTDispatchStrategy`, `functionKey`,
  `mouseButton4099`, `bindingMismatch`). Replaced by GVoice on purpose. `functionKey`
  and `mouseButton4099` were the two ways 0.2 could send the dictation shortcut — they
  were never triggers or actions a person could pick.
- **Internal Swift names** that differ because this is a rewrite, not a recovery:
  `KeyBinding` vs `TriggerBinding`, `NXKeyType` vs `KeyCode`, `ActionResult`,
  `TriggerDisplayInfo`, `shouldConsumeMediaKey` vs `shouldHandleConsumerKey`. Same
  behaviour, different spelling, nothing a person can see.

## Verified, again, on the real hardware

- `swift build` clean; both check scripts pass in full, including the new section that
  loads a 0.2-era file using every action name.
- Mark's live settings file: sha256 `d14e5f41…` before and after, untouched.
- The built app's menu, read live off the screen:
  `Devices: MX Master 3, MX Keys S` / `Disable Remapping` / `Reset to Defaults` /
  `Grant: Accessibility, Input Monitoring` / `GVoice: ready` / `Show Volume HUD` /
  `Settings...` / `Open Accessibility Settings` / `Quit Better Options`.
- The action picker, read live: Default (Pass Through), Volume Up, Volume Down, Toggle
  Mute, Brightness Up, Brightness Down, Play / Pause, Previous Track, Next Track, GVoice
  PTT — 0.2's ten, with GVoice in the dictation slot.
- Menu bar icon measured at 24 points wide, same as 0.2, and photographed for comparison.
- Test copies quit and deleted. Only the installed 0.2 (pid 1139) is running.

---

# Installed and pushed — 2026-08-14

**Installed.** `scripts/install.sh` ran with Mark's go. It saved the running 0.2 to
`/Users/macmini/.app-backups/BetterOptions/2026-08-14-014830/` first — checked, and that
folder holds a real app bundle reporting version 0.2, 728K. `/Applications/BetterOptions.app`
now reports `0.3` and is running (pid 40511 at the time). It sees both devices:
`Devices: MX Master 3, MX Keys S`. The menu bar slot measures 24 points, same as 0.2.

The installer's last line, `sudo launchctl load`, failed with "Expecting a LaunchDaemons
path" — macOS no longer accepts `load` for a LaunchAgent run as root, and the agent was
already registered anyway. Harmless: the plist is in place at
`/Library/LaunchAgents/com.dgcode88.betteroptions.plist`, it was started into the current
login session with `launchctl bootstrap gui/<uid>`, and it will start at login as before.

Mark's live settings file was not touched by the install: sha256 `d14e5f41…` before and
after.

**Pushed.** The rebuild is on `main` at `aicoder88/better-options`, commit `0a732b0`.
`main` and `origin/main` match. The `artifact/v0.2-binary` branch is untouched and still
holds the preserved 0.2 binary, locally and on GitHub.

## Still to do, and only Mark can do it

**Both permissions were revoked by the install, and until they are granted the mouse and
keyboard do nothing.** This is macOS behaviour, not a fault: replacing the app changes its
signature, so the old grants no longer apply. The app's own menu says which are missing —
right now `Grant: Accessibility, Input Monitoring`.

In System Settings → Privacy & Security:
- **Accessibility** — tick Better Options.
- **Input Monitoring** — tick Better Options.

If a stale entry is already listed, remove it with the minus button and add
`/Applications/BetterOptions.app` again, otherwise the tick can appear on without taking
effect. The menu line changes to `Accessibility granted` once both are through.

Not verified until that is done: an actual press of a remapped key or button doing the new
thing. Everything up to the event tap is checked; the tap itself cannot install without
Accessibility.
