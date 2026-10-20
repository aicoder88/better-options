import Foundation

/// Keeps a side button's press and release together: either both reach the
/// apps, or neither does.
///
/// Whether a press is taken for dictation is decided when it arrives, and the
/// answer can change before the release does (the mouse's own report lands a
/// moment later). Deciding the release afresh let a press through and kept its
/// release, so the Mac believed the button was still held. Every left click
/// after that counted as a second button joining in, and menus that open on a
/// fresh press stopped opening in Codex and opencode (2026-10-20).
struct SideButtonPairing {
    private var swallowedPress = false

    /// True when this press or release must be kept from the apps.
    /// `takePress` is only asked about presses.
    mutating func shouldSwallow(pressed: Bool, takePress: () -> Bool) -> Bool {
        if pressed {
            // Every press starts the pairing again, so a release that never
            // arrived (mouse unplugged mid-hold) cannot eat the next one.
            swallowedPress = takePress()
            return swallowedPress
        }
        let swallow = swallowedPress
        swallowedPress = false
        return swallow
    }
}
