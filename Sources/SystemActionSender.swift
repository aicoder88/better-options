import CoreGraphics
import Foundation

/// Fires the actions a trigger can be bound to, other than Handy push-to-talk (that one
/// goes through `HandyIntegration` instead, since it holds a recording open
/// rather than firing once).
///
/// Volume Up and Volume Down reuse `MediaKeySender`'s existing handling
/// unchanged. The rest post the same kind of system-defined media key event
/// `MediaKeySender` already uses for its own fallback, so every action in this
/// file behaves the way the real keyboard keys do.
final class SystemActionSender {
    private enum KeyCode {
        static let mute = 7
        static let brightnessUp = 2
        static let brightnessDown = 3
        static let play = 16
        static let next = 17
        static let previous = 18
    }

    private let mediaKeySender: MediaKeySender

    init(mediaKeySender: MediaKeySender = MediaKeySender()) {
        self.mediaKeySender = mediaKeySender
    }

    /// Fires `action` on this Mac. Returns the new system volume when the
    /// action changed it, so a caller can show the volume HUD; `nil` for
    /// every other action, including Default (Pass Through).
    ///
    /// Pass Through is not something this method does — it means "leave the
    /// trigger alone." A caller must check for it before deciding whether to
    /// call this at all, the same way `AppCoordinator` already checks
    /// `remappingEnabled` before touching a trigger.
    @discardableResult
    func perform(_ action: Action) -> Float? {
        switch action {
        case .passThrough:
            return nil
        case .volumeUp:
            return mediaKeySender.sendVolumeUp()
        case .volumeDown:
            return mediaKeySender.sendVolumeDown()
        case .toggleMute:
            mediaKeySender.sendMediaKey(KeyCode.mute)
        case .brightnessUp:
            mediaKeySender.sendMediaKey(KeyCode.brightnessUp)
        case .brightnessDown:
            mediaKeySender.sendMediaKey(KeyCode.brightnessDown)
        case .playPause:
            mediaKeySender.sendMediaKey(KeyCode.play)
        case .previousTrack:
            mediaKeySender.sendMediaKey(KeyCode.previous)
        case .nextTrack:
            mediaKeySender.sendMediaKey(KeyCode.next)
        case .previousApp:
            sendCommandTab()
        case .handyPTT:
            // Held, not fired: HandyIntegration.dispatchPTTEvent handles it.
            break
        default:
            // A future action name this build does not know yet: do nothing
            // rather than guess.
            break
        }
        return nil
    }

    /// One quick Cmd+Tab, which is how the Mac goes back to the app used last.
    /// It is what the mouse's own thumb button typed before it was taken over.
    private func sendCommandTab() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command: CGKeyCode = 0x37
        let tab: CGKeyCode = 0x30
        let events = [
            CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: tab, keyDown: true),
            CGEvent(keyboardEventSource: source, virtualKey: tab, keyDown: false),
            CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false),
        ]
        for (index, event) in events.enumerated() {
            // Command is held for the Tab in between, and let go at the end.
            event?.flags = index < 3 ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
    }
}
