# Better Options settings: per-device reset, a save that fails out loud, wheel controls

2026-09-10, Mac mini. Step 14 of
`/Users/macmini/dev/voice/docs/plans/gvoice-and-better-options-faster-safer-daily-use.md`.
Work done in `/Users/macmini/dev/better-options` on `main`. Nothing pushed. `/Applications`
untouched, so the app Drago is running today is unchanged.

**Claim (this file, 2026-09-10):** step 14 started and finished here, on top of step 13.
Step 11 also edits `AppCoordinator.swift`; it runs after this one.

## What was wrong, and what it does now

### Resetting one mouse wiped every other device

`resetToDefaults(deviceID:)` replaced the whole settings file with a fresh set of defaults
for the one device named. A person with a mouse and a keyboard who pressed "Reset to
Defaults" on the mouse lost every key they had ever set up on the keyboard, and the window
warned them about it in the past tense ("Saved bindings for other mice are cleared too")
rather than not doing it.

Now it drops only that device's bindings and puts that device's defaults back. A mouse gets
the wheel on volume and the side button on dictation. A keyboard gets Pass Through, which is
what a key with no binding already means, so its bindings are simply dropped. Everything
saved for every other device is left exactly where it was.

Two things ride along with that change:

- `enabled` is no longer reset. Resetting bindings used to switch remapping back on behind
  the person's back, and worse, the menu still said "off" because only the file changed.
- The window's warning now names the device it is about to change.

**Known limit:** a device id that is neither of the two models this build knows is treated as
a mouse, because that is the only default set there is. A future keyboard nobody has taught
this build about would be reset to a wheel and a side button it does not have. Harmless
today: two models are recognised, and both are known.

### A settings change that could not be saved vanished silently

`persist()` logged a line nobody reads and carried on. Memory kept the change, the file did
not, and the next launch quietly went back — so a person could switch remapping off, watch
the menu agree, and find it back on tomorrow with no idea why.

Now a failed write puts memory back to the last copy known to be on disk and tells the app,
which shows one alert naming the file and the reason. One alert per run: a settings window
being typed into would otherwise throw an alert per keystroke. The menu is rebuilt from the
file at the same time, so the on/off line cannot disagree with what was actually saved.

**Known limit:** the last-saved copy is only refreshed when this app reads or writes the
file. If something else rewrites the file behind us and our next write then fails, memory
goes back to our copy rather than theirs.

### The wheel fired everything at once, one tick at a time

A single flick of the thumb wheel sends a burst of ticks. Each one moved the volume a step
and drew its own volume window animation on top of the last, which is what made the wheel
feel jittery.

Ticks going the same way on the same mouse are now gathered for 30 ms and acted on together:
the same number of volume steps, one volume window. A change of direction, or a hand moving
to a different mouse, hands over whatever is waiting first, so a flick one way can never be
swallowed into a flick the other way. Dictation on the wheel is never gathered at all — a
held-back tick would mean the microphone opening late.

### Two new wheel settings

"Wheel sensitivity" (every tick, every 2, up to every 5) and "Reverse wheel" now sit in the
settings window, above the list of controls, for a mouse only. Both start on what the wheel
has always done, and **neither is written into the settings file until it is moved off that
value** — so a file saved by the 0.2 build still reads and writes back byte for byte the
same, which is the check this step had to keep passing.

### The settings window went stale while it was open

A mouse plugged in or unplugged while the window sat open did not show up until the window
was closed and opened again. It now re-reads what is connected every two seconds while it is
visible, and stops on its own once it is not. Nothing is written back to the screen unless it
actually changed, so an open picker is not yanked out from under a hand.

## What was run

| Command | Result |
| --- | --- |
| `swift build` | Build complete, exit 0 |
| `scripts/check-settings.sh` | All checks passed, exit 0. The recovered 0.2 file and the real file on this Mac both still round-trip byte for byte (491 bytes each), and the real file was left alone |
| `scripts/check-settings-window.sh` | All checks passed, exit 0 |

Twenty-seven new cases across the two checks: resetting one of three devices and proving the
other two untouched, resetting a keyboard back to Pass Through with remapping left off, the
wheel settings saving and then leaving the file byte-identical when put back, a number out of
range being pulled into range, a file that cannot be written reporting once and undoing its
own change, and eight on gathering up a flick of the wheel, including the two that prove a
change of direction is never merged into the flick before it.

`Sources/WheelCoalescer.swift` is compiled into `scripts/check-settings.sh` so the flick
rules can be checked without a hand on the mouse.

## UNVERIFIED — needs a person at the machine

1. **The alert when the settings file cannot be written.** This is step 14's manual verify
   line. The store half is automated (a file that cannot be written reports once and undoes
   its own change). The alert itself is not: showing it needs the real app pointed at the
   real settings file. To do it by hand: run `chmod 500 ~/Library/Application\ Support/BetterOptions`,
   open Better Options' Settings window, change any binding, and expect one alert saying the
   settings could not be saved and the change was undone. Then `chmod 700` that folder again.
   Do it with a copy of the file saved first.
2. **A flick of the wheel still changes the volume by the same amount**, and does it without
   a stutter. Flick the thumb wheel sideways in both directions and watch the volume window.
3. **A flick the other way is not swallowed.** Flick left then immediately right; the volume
   must go down then up, not down twice.
4. **Reverse wheel does what it says.** Switch it on and flick; the volume must move the
   opposite way to before.
5. **Wheel sensitivity slows the wheel.** Set it to every 3 ticks; a short flick must move
   the volume less than it did.
6. **Resetting the mouse leaves the keyboard alone**, in the real window: set a keyboard key
   to something, reset the mouse, and confirm the key is still set.
7. **A mouse plugged in while the settings window is open appears in it** within two seconds.

Nothing in this step was tried against real hardware. The gathering delay (30 ms) is a
judgement, not a measurement.
