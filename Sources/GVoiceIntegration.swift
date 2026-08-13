import AppKit
import CoreGraphics
import Foundation

/// Drives GVoice's hold-to-talk dictation from the mouse's back side button.
///
/// GVoice accepts three hold-to-talk triggers: right Option, left Ctrl + left
/// Cmd held together, and the raw mouse "back" button. Better Options swallows
/// that raw button (so holding it stops also firing browser-back), so we hand
/// GVoice the left Ctrl + left Cmd chord instead — the fallback its own hotkey
/// code documents for exactly this case.
final class GVoiceIntegration {
    enum InstallState: Equatable {
        case installed
        case notInstalled
    }

    typealias Callback = () -> Void

    private let bundleIdentifier = "com.purr.gvoice"
    private static let controlLeftKeyCode: CGKeyCode = 0x3B
    private static let commandLeftKeyCode: CGKeyCode = 0x37

    var onStateChange: Callback?
    private(set) var installState: InstallState = .notInstalled
    private var chordIsHeld = false

    var runningPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
    }

    func refreshConfiguration() {
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        installState = found ? .installed : .notInstalled
        onStateChange?()
    }

    func dispatchPTTEvent(pressed: Bool, location: CGPoint) {
        if pressed {
            guard !chordIsHeld else {
                return
            }
            chordIsHeld = true
            postModifier(Self.controlLeftKeyCode, flags: .maskControl)
            postModifier(Self.commandLeftKeyCode, flags: [.maskControl, .maskCommand])
        } else {
            guard chordIsHeld else {
                return
            }
            chordIsHeld = false
            postModifier(Self.commandLeftKeyCode, flags: .maskControl)
            postModifier(Self.controlLeftKeyCode, flags: [])
        }
    }

    /// Flips the chord: down if it isn't held, up if it is.
    ///
    /// Used by a trigger that fires one momentary event instead of being held
    /// down — the thumb wheel has no separate press and release to bind PTT
    /// to, so a tick starts the hold and the next tick ends it.
    func togglePTT() {
        dispatchPTTEvent(pressed: !chordIsHeld, location: .zero)
    }

    /// Releases a chord left hanging (mouse unplugged, remapping switched off)
    /// so GVoice can't keep recording with no way to stop it.
    func releaseHeldChord() {
        guard chordIsHeld else {
            return
        }
        dispatchPTTEvent(pressed: false, location: .zero)
    }

    /// Posts a modifier key as a real flags-change event, with `flags` holding
    /// the FULL set of modifiers that should be down afterwards.
    ///
    /// It has to be a flags-change and not a plain key-down: the event library
    /// GVoice listens through only updates its "which modifiers are down" mask
    /// from flags-change events. Send a key-down instead and GVoice sees Ctrl
    /// reported as not-held while Cmd arrives, decides the earlier Ctrl press
    /// was stale, drops it, and the chord never completes.
    private func postModifier(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return
        }

        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
