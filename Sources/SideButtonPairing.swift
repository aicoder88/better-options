import Foundation

/// Keeps a side button's press and release together: either both reach the
/// apps, or neither does. And a press that reached the apps does only that:
/// the button's own action stays quiet for it.
///
/// Whether a press is taken for dictation is decided when it arrives, and the
/// answer can change before the release does (the mouse's own report lands a
/// moment later). Deciding the release afresh let a press through and kept its
/// release, so the Mac believed the button was still held. Every left click
/// after that counted as a second button joining in, and menus that open on a
/// fresh press stopped opening in Codex and opencode (2026-10-20).
///
/// Each button keeps its own pairing. One shared flag let a back button held
/// over a forward button eat the forward button's release, the same stuck
/// button by another road.
struct SideButtonPairing {
    /// How close together the mouse's own report and the Mac's click must land
    /// to count as the same press.
    static let window: TimeInterval = 0.08

    private var swallowedButtons: Set<Int64> = []
    private var lastPassedPressAt: TimeInterval?

    /// True when this press or release must be kept from the apps.
    /// `takePress` is only asked about presses.
    mutating func shouldSwallow(button: Int64, pressed: Bool, at now: TimeInterval, takePress: () -> Bool) -> Bool {
        guard pressed else {
            return swallowedButtons.remove(button) != nil
        }
        // Every press starts its button's pairing again, so a release that
        // never arrived (mouse unplugged mid-hold, or sent while macOS had
        // switched the tap off) cannot eat the next one.
        if takePress() {
            swallowedButtons.insert(button)
            return true
        }
        swallowedButtons.remove(button)
        lastPassedPressAt = now
        return false
    }

    /// True when a side-button press just reached the apps. The mouse's own
    /// report of that same press, landing a moment later, must not fire the
    /// button's action on top of it (a browser Back plus an app switch).
    func pressReachedApps(at now: TimeInterval) -> Bool {
        guard let lastPassedPressAt else {
            return false
        }
        return now - lastPassedPressAt <= Self.window
    }
}
