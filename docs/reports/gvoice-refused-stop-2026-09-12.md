# A refused stop must not hang up on GVoice (2026-09-12)

Branch `worktree-gvoice-stop-refusal`, working copy
`/Users/macmini/dev/better-options/.claude/worktrees/gvoice-stop-refusal`.
Nothing committed, nothing merged into `main`, nothing installed.

A worktree because `main` holds someone else's uncommitted work from 14:51
(`Sources/HIDDeviceMonitor.swift` and the built binary under `dist/`). That work
is untouched here.

## Why this had to change

GVoice's control socket used to obey a `stop` it could not attribute to any
press: main.js reads a missing session id as "whatever is live", so a companion
whose own `start` had been refused as `busy` could end the dictation the user was
holding on the keyboard, mid-sentence. That is fixed in the voice repo today
(`/Users/macmini/dev/voice`, finding 1 of
`docs/reports/code-review-fixes-2026-09-12.md`): an unattributable `stop` or
`cancel` now comes back as `{"type":"refuse","reason":"session"}`.

That made a refusal reachable for a message Better Options routinely sends, and
`handleRefusal` treated any refusal it could not match to a press in flight as a
problem with the CONNECTION: it called `dropConnection(unavailable: true)`. The
side button would then pass through as an ordinary back-click until GVoice was
restarted — a worse fault than the one being fixed.

## The change

`Sources/GVoiceIntegration.swift`, `handleRefusal`: a refusal that NAMES one of
our requests is about that one request. GVoice carries a `requestId` on every
answer to a message we sent, and leaves it off only when the refusal is about the
connection itself (wrong version, another companion already attached, a malformed
frame). So:

- refusal naming the press in flight → the press never started (unchanged);
- refusal naming anything else of ours → log it, and if we still think we are
  holding, stop thinking so. Stay connected;
- refusal naming nothing → still a connection problem, still hang up.

No change to what Better Options sends. Its `stop` already carries the session id
from the `start` ack, and it never sends `cancel` at all. GVoice's other change
today (reporting the real microphone mode instead of a hardcoded "balanced")
needs nothing here: nothing in this app reads `micMode`.

## Checked

`sh scripts/check-gvoice-socket.sh` — PASS, with two new lines:

```
  ok: a refused stop leaves dictation on offer
  ok: and does not hang up on GVoice
```

The stand-in GVoice in `scripts/gvoice-socket-check/main.swift` learned to refuse
one stop (`refuseNextStop()`), and to count messages instead of merely looking
for them, since a second press has to be told apart from the first.

With the fix reverted the same check fails, which is what gives it teeth:

```
FAIL: a refused stop leaves dictation on offer
```

`swift build` — Build complete.

## Not done

- Not installed. `/Applications/BetterOptions.app` is still the old binary, and
  installing from this worktree would drop the uncommitted mouse-device work that
  `main` is carrying.
- The physical side button was not pressed. The check drives
  `dispatchPTTEvent(pressed:)` directly; a real HID press stays a hand check, as
  the harness itself says.
