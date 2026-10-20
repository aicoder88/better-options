import Foundation

let back: Int64 = 3
let forward: Int64 = 4
var pairing = SideButtonPairing()

// The fault seen on 2026-10-20: the press went through, then the mouse's own
// report arrived and the release would have been kept. The release must go
// through, or the Mac thinks the button is still held.
precondition(!pairing.shouldSwallow(button: back, pressed: true, at: 0) { false })
precondition(!pairing.shouldSwallow(button: back, pressed: false, at: 0.2) { fatalError("releases are never asked") },
             "A release whose press went through must go through too")

// A kept press keeps its release.
precondition(pairing.shouldSwallow(button: back, pressed: true, at: 1) { true })
precondition(pairing.shouldSwallow(button: back, pressed: false, at: 1.2) { false })

// A release that never arrived cannot eat the next press's release.
precondition(pairing.shouldSwallow(button: back, pressed: true, at: 2) { true })
precondition(!pairing.shouldSwallow(button: back, pressed: true, at: 3) { false })
precondition(!pairing.shouldSwallow(button: back, pressed: false, at: 3.2) { true })

// Forward held, back pressed and kept, forward let go first: forward's
// release must still reach the apps, and back's must still be kept.
precondition(!pairing.shouldSwallow(button: forward, pressed: true, at: 4) { false })
precondition(pairing.shouldSwallow(button: back, pressed: true, at: 4.5) { true })
precondition(!pairing.shouldSwallow(button: forward, pressed: false, at: 5) { true },
             "Another button's kept press must not eat this button's release")
precondition(pairing.shouldSwallow(button: back, pressed: false, at: 5.5) { false })

// Back kept, forward pressed through, back let go: back's release stays kept.
precondition(pairing.shouldSwallow(button: back, pressed: true, at: 6) { true })
precondition(!pairing.shouldSwallow(button: forward, pressed: true, at: 6.5) { false })
precondition(pairing.shouldSwallow(button: back, pressed: false, at: 7) { false },
             "Another button's press must not free this button's kept release")
precondition(!pairing.shouldSwallow(button: forward, pressed: false, at: 7.5) { true })

// A press that went through to the apps keeps the button's action quiet for
// that same press, and only for it.
var fresh = SideButtonPairing()
precondition(!fresh.pressReachedApps(at: 10))
_ = fresh.shouldSwallow(button: back, pressed: true, at: 10) { false }
precondition(fresh.pressReachedApps(at: 10 + SideButtonPairing.window / 2),
             "A click that reached the apps must not also fire the button's action")
precondition(!fresh.pressReachedApps(at: 10 + SideButtonPairing.window * 2))
_ = fresh.shouldSwallow(button: back, pressed: true, at: 20) { true }
precondition(!fresh.pressReachedApps(at: 20), "A kept press fires the action")

print("Side button press and release stay paired, one action per press")
