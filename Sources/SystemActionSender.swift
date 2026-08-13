import Foundation

/// Fires the actions a trigger can be bound to, other than GVoice PTT (that one
/// goes through `GVoiceIntegration` instead, since it holds a chord down rather
/// than firing once).
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
        case .gvoicePTT:
            // Held, not fired — GVoiceIntegration.dispatchPTTEvent handles it.
            break
        default:
            // A future action name this build does not know yet: do nothing
            // rather than guess.
            break
        }
        return nil
    }
}
