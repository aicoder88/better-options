import Foundation

var pairing = SideButtonPairing()

// The fault seen on 2026-10-20: the press went through, then the mouse's own
// report arrived and the release would have been kept. The release must go
// through, or the Mac thinks the button is still held.
precondition(!pairing.shouldSwallow(pressed: true) { false })
precondition(!pairing.shouldSwallow(pressed: false) { fatalError("releases are never asked") },
             "A release whose press went through must go through too")

// A kept press keeps its release.
precondition(pairing.shouldSwallow(pressed: true) { true })
precondition(pairing.shouldSwallow(pressed: false) { false })

// A release that never arrived cannot eat the next press's release.
precondition(pairing.shouldSwallow(pressed: true) { true })
precondition(!pairing.shouldSwallow(pressed: true) { false })
precondition(!pairing.shouldSwallow(pressed: false) { true })

print("Side button press and release stay paired")
