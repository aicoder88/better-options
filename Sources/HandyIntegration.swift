import AppKit
import Darwin

/// Hold-to-talk dictation through Handy.
///
/// Handy starts or stops a plain transcription every time it receives SIGUSR2
/// (the same thing `handy --toggle-transcription` sends). No keys are faked and
/// nothing has to match Handy's own shortcut: the button going down sends one
/// signal, the button coming up sends the next.
@MainActor
final class HandyIntegration {
    typealias Callback = () -> Void

    nonisolated static let bundleIdentifier = "com.pais.handy"

    var onStateChange: Callback?

    private(set) var isRunning = false
    private(set) var isHolding = false
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Handy is open, so a press will be heard.
    var isReady: Bool {
        isRunning
    }

    private var runningPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first { !$0.isTerminated }?
            .processIdentifier
    }

    func refreshConfiguration() {
        observeWorkspaceIfNeeded()
        updatePresence()
    }

    func dispatchPTTEvent(pressed: Bool) {
        if pressed {
            startHold()
        } else {
            releaseHold()
        }
    }

    /// For a control with no separate release, such as a wheel tick.
    func togglePTT() {
        if isHolding {
            releaseHold()
        } else {
            startHold()
        }
    }

    func releaseHold() {
        guard isHolding else {
            return
        }
        isHolding = false
        signalHandy()
    }

    private func startHold() {
        guard !isHolding else {
            return
        }
        isHolding = signalHandy()
    }

    /// Sends Handy its start/stop signal. False when Handy is not there to hear it.
    @discardableResult
    private func signalHandy() -> Bool {
        guard let pid = runningPID else {
            updatePresence()
            return false
        }
        return kill(pid, SIGUSR2) == 0
    }

    private func observeWorkspaceIfNeeded() {
        guard workspaceObservers.isEmpty else {
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleIdentifier else {
                    return
                }
                MainActor.assumeIsolated {
                    self?.updatePresence()
                }
            }
            workspaceObservers.append(token)
        }
    }

    private func updatePresence() {
        let running = runningPID != nil
        if !running {
            // Handy quit mid-hold: there is nothing left to stop.
            isHolding = false
        }
        guard running != isRunning else {
            return
        }
        isRunning = running
        onStateChange?()
    }
}
