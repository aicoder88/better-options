# Better Options control faults: what reproduced, what did not

2026-09-10, Mac mini. Step 13 of
`/Users/macmini/dev/voice/docs/plans/gvoice-and-better-options-faster-safer-daily-use.md`.
Work done in `/Users/macmini/dev/better-options` on `main`. Nothing pushed.

**Claim (this file, 2026-09-10):** step 13 started and finished here. Steps 14 and 11
also edit `AppCoordinator.swift` and `SettingsStore.swift`; they run after this one.

Every claim below was reproduced first, on the code as it stood, before anything was
changed. Reproduction ran two ways: a throwaway harness compiled against the real
`SettingsStore.swift` and `DeviceRegistry.swift`, and `grep` over the sources for the
call that was supposed to exist and did not.

## (a) The saved on/off switch is ignored at launch — REPRODUCED, FIXED

`AppCoordinator.remappingEnabled` was born `true` (a literal, line 33). `start()` read the
settings file and then never looked at `enabled`. `toggleRemapping()` flipped the property
and never wrote it back. So switching remapping off, quitting and relaunching came back on,
and the saved value drifted from the menu forever after.

Reproduction: harness loaded `{"enabled":false}` and got `isEnabled == false` from the
store, while `grep -n "remappingEnabled" Sources/` showed no read of and no write to
`settingsStore.isEnabled` anywhere.

Fix: `start()` seeds `remappingEnabled` from the file after the menu is built, and the
property's `didSet` writes the new value straight back to the store.

## (b) Pass Through on the thumb wheel — REPRODUCED for the wheel only, FIXED

`EventTapController.handleScroll` swallowed every sideways wheel tick whenever remapping was
on, a known device was plugged in, and the mouse had just reported a tick. It never consulted
what the wheel was bound to. With the wheel set to Default (Pass Through) the tick was
swallowed and nothing was fired in its place, so the wheel did nothing at all instead of
scrolling sideways.

Not reproduced for the side button (`shouldHandleSideButton` already returned false on Pass
Through) or for keyboard keys (`shouldHandleConsumerKey` already did the same).

Fix: a new `shouldHandleThumbWheel` gate on the event tap, wired to the wheel's bindings.

**Known limit, on purpose:** the gate asks about the wheel, not about one direction of it.
A sideways scroll event and the mouse's own HID report of the tick do not have to agree on
which way is which, and guessing wrong would swallow the wrong half. So a wheel with one
direction bound and the other on Pass Through still has both directions swallowed, exactly
as before. Both directions on Pass Through is the case that is fixed.

## (c) An action name this build does not know — HALF REPRODUCED, FIXED

*Not* reproduced: the name is **not** dropped from the file. `Action` decodes any string and
writes the same string back, and `Trigger` does the same for control names. A file naming
`somethingNewer` loads and saves with the name intact; the settings check has proved this for
`wisprPTT` since the rebuild.

Reproduced: the name is not treated as pass-through either. `shouldHandleConsumerKey` and
`shouldHandleSideButton` asked only "is this Pass Through?", so an unrecognised name answered
"yes, take the event". The event tap swallowed the key or the click, and
`SystemActionSender.perform` then fell into `default: break` and did nothing. The control went
dead: neither its own job nor the new one.

Fix: a new `Action.isSupported` — dictation, or one of the actions this build actually
performs. All three event-tap gates now use it, so an unknown name is left alone and the key
keeps doing what it is printed with. Kept in the file, as before.

## (d) HID callbacks and device identity — HALF REPRODUCED, HALF FIXED

Reproduced, part one: `DeviceRegistry.activeDevice` answered `connected.first { .mouse } ??
connected.first`. With only the MX Keys S plugged in, the keyboard was handed back as "the
active mouse", so every mouse control was looked up under `mx-keys-s`. The harness printed
`activeDevice = mx-keys-s type=keyboard`.

Reproduced, part two: `onThumbWheelEvent`, `onPTTButtonEvent` and `onConsumerKeyEvent` carried
no device id at all. `AppCoordinator` resolved the binding through `currentDeviceID()` /
`currentKeyboardID()` — whichever device happened to be first in the registry — rather than
the device the hand was actually on.

Fix: all three callbacks now carry the id of the device that sent the event, and the
coordinator binds against that id. `activeDevice` is now a mouse or nothing. A release is
answered by the device that began the hold, so swapping a mouse mid-hold cannot leave the
first one recording.

**Not reproduced: an event delivered twice.** `start()` registers an input-value callback on
the manager (line 94) *and* one on each device (line 153). Reading IOKitUser, the manager
applies its callback by calling `IOHIDDeviceRegisterInputValueCallback` on each device — the
same single per-device slot. The later registration replaces the earlier one; both point at
this app's own `handleInputValue`, so either way the handler runs once. The pair is redundant
and confusing, not a double delivery. **Left alone deliberately**: removing one of them
changes how the mouse is read, and the only way to prove the mouse still works is a physical
press, which no agent can perform. See UNVERIFIED below.

**Not fixable at the event tap:** a `CGEvent` carries no device identity. So "did the MX
Master's wheel just tick" and "did the MX Keys S just send Volume Up" remain time-window
questions (200 ms) that any second mouse or keyboard could answer by accident. Only one mouse
model and one keyboard model are recognised today, so this cannot bite yet.

## (e) A held control on the way out — REPRODUCED, FIXED (one part best-effort)

`grep` found exactly one call to `releaseHeldChord()`: remapping being switched off. Nothing
released a hold when the mouse was unplugged, when the binding changed under it, when the Mac
went to sleep, or when the app quit. `AppDelegate` had no `applicationWillTerminate` at all
and nothing anywhere watched for sleep. A hold left up leaves GVoice recording with nothing
on this Mac able to stop it — the exact stall the plan exists to end.

Fix: one `releaseHeldControls()` on the coordinator, called from every way out —

- remapping switched off (as before),
- the holding device unplugged (`deviceMonitor.onStateChange`),
- the held control pointed at something else (`settingsStore.onChange`, newly wired),
- the Mac sleeping, shutting down, or the user switching away
  (`willSleep`, `willPowerOff`, `sessionDidResignActive`),
- the app quitting (`applicationWillTerminate`).

**Best-effort only: Accessibility permission lost.** The release is attempted, but letting go
means posting an event, and posting needs the very permission that was just taken away. If
macOS revokes Accessibility mid-hold there is no way to send the release. Nothing detects a
revocation while permission was previously granted, either; the app only polls while
permission is already missing.

## What was run

| Command | Result |
| --- | --- |
| `swift build` | Build complete, exit 0 |
| `scripts/check-settings.sh` | All checks passed, exit 0. The recovered 0.2 file and the real file on this Mac both round-trip byte for byte (491 bytes each), and the real file was left alone |
| `scripts/check-settings-window.sh` | All checks passed, exit 0 |

Nine new cases were added to `scripts/settings-check/main.swift`: five on `Action.isSupported`,
three on a file written by a future build (loads, both controls left alone, name still in the
file after a save), and four on a keyboard never answering as the mouse.

## UNVERIFIED — needs a person at the machine

None of these can be done by an agent. Each needs a hand on the hardware.

1. **Quit with remapping off, relaunch, menu shows off.** Open the Better Options menu, pick
   "Disable Remapping", quit, relaunch, open the menu. It must read "Enable Remapping". This is
   the manual half of step 13's verify line.
2. **Pass Through wheel scrolls sideways again.** Set both wheel directions to Default (Pass
   Through) in Settings, then flick the thumb wheel in a wide window. The window must scroll
   sideways.
3. **The mouse still works at all.** The device-identity change touched how HID events are
   dispatched. Press the side button and flick the wheel once each and confirm both still do
   what they are bound to.
4. **Unplug the mouse mid-hold.** Hold the side button with GVoice running, unplug the mouse's
   receiver, and confirm dictation stops instead of recording forever.
5. **Sleep the Mac mid-hold.** Hold the side button, close the lid or sleep the Mac, wake it,
   and confirm dictation is not still running.
6. **Quit mid-hold.** Hold the side button and quit Better Options from its menu; dictation
   must stop.
7. **Change the binding mid-hold.** Hold the side button, and with the Settings window open
   point the side button at Volume Up; dictation must stop.
8. **An event delivered twice.** Proving or disproving the double registration needs a real
   press with Input Monitoring granted to a scratch binary. Not attempted.

Items 4 through 7 all exercise the same one call, `releaseHeldControls()`, from five different
places. Item 6 is the cheapest of them to try.
