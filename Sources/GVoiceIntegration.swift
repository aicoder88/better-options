import AppKit
import Foundation
import Network
import os

/// Asks GVoice to dictate, in words, over a local socket.
///
/// What this replaced, and why: Better Options used to hold down a fake
/// Ctrl+Cmd for as long as the mouse's side button was down, because that chord
/// is one of GVoice's hold-to-talk triggers. Anything that ate the release — a
/// crash, Accessibility being revoked, a Space switch — left both modifiers
/// stuck down and the microphone recording with nothing able to stop it.
///
/// Now the two apps talk. Better Options says "start" and "stop"; GVoice
/// answers. Nothing is typed, no modifier is ever posted, and if Better Options
/// stops saying anything at all GVoice ends the recording by itself six seconds
/// later. A dead companion can no longer hold the microphone open.
///
/// The socket lives inside GVoice's own application-support folder, in a
/// 0700 directory, so it is reachable by this user and nobody else. A GVoice
/// launched with its own data folder (the isolated dev launch) serves a
/// different socket; `BETTEROPTIONS_GVOICE_SOCKET` points this app at it.
final class GVoiceIntegration {
    enum InstallState: Equatable {
        case installed
        case notInstalled
    }

    /// How the conversation with GVoice is going, as far as the menu cares.
    enum ConnectionState: Equatable {
        /// Nothing to talk to: GVoice is not running.
        case idle
        /// Trying, or waiting out a backoff before trying again.
        case connecting
        /// Handshake done, heartbeats flowing.
        case connected
        /// GVoice is running but the socket is not there or refused us. Almost
        /// always an older GVoice that has no socket to offer.
        case unavailable
    }

    typealias Callback = () -> Void

    private let bundleIdentifier = "com.purr.gvoice"

    /// GVoice's control socket. The default is the installed app's; the
    /// environment variable exists so a dev copy of GVoice running on its own
    /// data folder can be driven without touching the real one.
    static let socketPath: String = {
        if let override = ProcessInfo.processInfo.environment["BETTEROPTIONS_GVOICE_SOCKET"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/GVoice/control/gvoice.sock")
            .path
    }()

    private static let protocolVersion = 1
    private static let clientName = "BetterOptions"
    /// GVoice hangs up after six seconds of silence, so beat well inside that.
    private static let heartbeatInterval: TimeInterval = 2
    private static let minimumRetryDelay: TimeInterval = 0.25
    private static let maximumRetryDelay: TimeInterval = 5
    /// How often we look to see whether GVoice has appeared or gone away, for
    /// the cases the workspace notifications do not cover (a crash, say).
    private static let presencePollInterval: TimeInterval = 5
    private static let maximumFrameBytes = 4096

    private static let log = Logger(subsystem: "com.purr.betteroptions", category: "gvoice")

    /// Where a press is in its life. `starting` covers the gap between asking
    /// GVoice to record and GVoice saying it has: a release landing in that gap
    /// must not be thrown away.
    private enum HoldState: Equatable {
        case idle
        case starting(requestID: String, stopWhenAcked: Bool)
        case holding(sessionID: String?)
    }

    var onStateChange: Callback?

    private(set) var installState: InstallState = .notInstalled

    /// Everything below is read and written on the main thread only. The event
    /// tap callback runs there too, so deciding whether to swallow a click is a
    /// plain read of a cached flag — never a socket round trip in the middle of
    /// someone's mouse click.
    private(set) var connectionState: ConnectionState = .idle
    private(set) var isRunning = false
    /// GVoice's own answer to "could I start dictating right now".
    private(set) var engineReady = false

    private var holdState: HoldState = .idle
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var retryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = GVoiceIntegration.minimumRetryDelay
    private var presenceTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var readBuffer = Data()
    private var requestCounter: UInt64 = 0

    private let queue = DispatchQueue(label: "com.purr.betteroptions.gvoice-socket")

    /// The one flag the event tap reads: is there a GVoice on the other end
    /// that says it can record right now?
    var isReady: Bool {
        connectionState == .connected && engineReady
    }

    /// Is a dictation being held down right now? Read by the coordinator so it
    /// can let go on the way out — sleep, quit, mouse unplugged.
    var isHolding: Bool {
        holdState != .idle
    }

    var runningPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .processIdentifier
    }

    deinit {
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        presenceTimer?.invalidate()
    }

    // MARK: - Life cycle

    /// Works out whether GVoice is installed and running, and starts (or stops)
    /// trying to talk to it.
    func refreshConfiguration() {
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        installState = found ? .installed : .notInstalled

        observeWorkspaceIfNeeded()
        startPresencePollingIfNeeded()
        updatePresence(notify: true)
    }

    private func observeWorkspaceIfNeeded() {
        guard workspaceObservers.isEmpty else {
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updatePresence(notify: true)
            }
            workspaceObservers.append(token)
        }
    }

    private func startPresencePollingIfNeeded() {
        guard presenceTimer == nil else {
            return
        }

        // A crashed GVoice sends no notification, and a socket that appears a
        // moment after the app does needs a second look.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.presencePollInterval, repeats: true) { [weak self] _ in
            self?.updatePresence(notify: true)
        }
        timer.tolerance = 1
        presenceTimer = timer
    }

    /// GVoice appearing or going away is the only thing that starts or stops
    /// the conversation.
    private func updatePresence(notify: Bool) {
        let running = runningPID != nil
        let changed = running != isRunning
        isRunning = running

        if running {
            connectIfNeeded()
        } else if changed {
            teardown(reason: "GVoice is not running")
        }

        if notify, changed {
            onStateChange?()
        }
    }

    // MARK: - The socket

    private func connectIfNeeded() {
        guard connection == nil, retryWorkItem == nil else {
            return
        }

        connectionState = .connecting
        readBuffer.removeAll(keepingCapacity: false)

        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            DispatchQueue.main.async {
                self.handleConnectionState(state, of: connection)
            }
        }

        receive(on: connection)
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection else {
            return
        }

        switch state {
        case .ready:
            Self.log.info("connected to GVoice at \(Self.socketPath, privacy: .public)")
            send(["type": "hello", "version": Self.protocolVersion, "client": Self.clientName])
            startHeartbeat()
        case .failed(let error):
            Self.log.info("GVoice socket failed: \(String(describing: error), privacy: .public)")
            dropConnection(unavailable: true)
        case .cancelled:
            break
        case .waiting(let error):
            // With a unix socket "waiting" means the file is not there or is
            // not accepting: an older GVoice with no socket to offer. Do not
            // sit in it, or the menu never says so.
            Self.log.info("GVoice socket waiting: \(String(describing: error), privacy: .public)")
            dropConnection(unavailable: true)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            if let data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.ingest(data, from: connection)
                }
            }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard connection === self.connection else {
                        return
                    }
                    Self.log.info("GVoice closed the socket")
                    self.dropConnection(unavailable: true)
                }
                return
            }

            self.receive(on: connection)
        }
    }

    private func ingest(_ data: Data, from connection: NWConnection) {
        guard connection === self.connection else {
            return
        }

        readBuffer.append(data)

        while let newline = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = readBuffer[readBuffer.startIndex..<newline]
            readBuffer = readBuffer[readBuffer.index(after: newline)...]
            if !line.isEmpty {
                handle(frame: Data(line))
            }
        }

        // A GVoice that never sends a newline must not grow this buffer for
        // ever. The limit is GVoice's own frame limit, read the other way.
        if readBuffer.count > Self.maximumFrameBytes {
            Self.log.error("GVoice sent an oversized frame — hanging up")
            dropConnection(unavailable: true)
        }
    }

    private func handle(frame: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = object["type"] as? String else {
            Self.log.error("unreadable frame from GVoice — hanging up")
            dropConnection(unavailable: true)
            return
        }

        switch type {
        case "status":
            retryDelay = Self.minimumRetryDelay
            let wasReady = isReady
            connectionState = .connected
            engineReady = (object["ready"] as? Bool) ?? false
            if isReady != wasReady {
                onStateChange?()
            }
        case "ack":
            handleAck(object)
        case "refuse":
            handleRefusal(object)
        default:
            break
        }
    }

    private func handleAck(_ object: [String: Any]) {
        guard case .starting(let requestID, let stopWhenAcked) = holdState else {
            return
        }
        guard (object["requestId"] as? String) == requestID else {
            return
        }

        let sessionID = object["sessionId"] as? String
        holdState = .holding(sessionID: sessionID)
        Self.log.info("GVoice is recording, session \(sessionID ?? "unnamed", privacy: .public)")

        if stopWhenAcked {
            // The button came back up before GVoice answered. Stop now, or the
            // microphone stays open with nothing left to close it.
            stopHold(reason: "release-arrived-early")
        }
    }

    private func handleRefusal(_ object: [String: Any]) {
        let reason = (object["reason"] as? String) ?? "unknown"
        let requestID = object["requestId"] as? String

        if case .starting(let pressID, _) = holdState, requestID == pressID {
            Self.log.info("GVoice refused the press: \(reason, privacy: .public)")
            holdState = .idle
            onStateChange?()
            return
        }

        // Any other refusal that NAMES one of our requests is about that one
        // request and nothing more — GVoice carries a requestId on every answer
        // to a message we sent, and leaves it off only when the refusal is about
        // the connection itself. Hanging up here is what this used to do, and it
        // is the wrong answer to the commonest case: GVoice now refuses a stop
        // for a press it no longer holds (a release that lost its race, a stop
        // we sent twice), which would have taken the mouse button out of service
        // until GVoice was restarted. The press is over either way, so match the
        // state to that and stay connected.
        if requestID != nil {
            Self.log.info("GVoice refused \(requestID ?? "", privacy: .public): \(reason, privacy: .public)")
            if case .holding = holdState {
                holdState = .idle
                onStateChange?()
            }
            return
        }

        // A refusal with no request behind it is about the connection itself —
        // wrong protocol version, or another companion already has GVoice.
        Self.log.info("GVoice refused the connection: \(reason, privacy: .public)")
        dropConnection(unavailable: true)
    }

    private func send(_ message: [String: Any]) {
        guard let connection else {
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .idempotent)
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.send(["type": "heartbeat"])
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// Lose the connection: forget the press it was carrying, tell the menu,
    /// and line up another try while GVoice is still running.
    private func dropConnection(unavailable: Bool) {
        let wasReady = isReady
        let wasHolding = isHolding

        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        readBuffer.removeAll(keepingCapacity: false)
        engineReady = false
        // GVoice ends a companion-owned recording by itself when we stop
        // talking, so there is nothing left to send. Forget it on this side.
        holdState = .idle
        connectionState = isRunning ? (unavailable ? .unavailable : .connecting) : .idle

        if isRunning {
            scheduleRetry()
        }

        if wasReady || wasHolding || connectionState != .connected {
            onStateChange?()
        }
    }

    private func scheduleRetry() {
        guard retryWorkItem == nil else {
            return
        }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)

        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.retryWorkItem = nil
            guard self.isRunning else {
                return
            }
            self.connectIfNeeded()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardown(reason: String) {
        Self.log.info("dropping the GVoice connection: \(reason, privacy: .public)")
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryDelay = Self.minimumRetryDelay
        dropConnection(unavailable: false)
        connectionState = .idle
    }

    // MARK: - Dictation

    /// Holds dictation for exactly as long as the button is down.
    func dispatchPTTEvent(pressed: Bool) {
        if pressed {
            startHold()
        } else {
            stopHold(reason: "release")
        }
    }

    /// Flips dictation: start if nothing is running, stop if it is.
    ///
    /// Used by a trigger that fires one momentary event instead of being held
    /// down — the thumb wheel has no separate press and release, so a tick
    /// starts the recording and the next tick ends it.
    func togglePTT() {
        if isHolding {
            stopHold(reason: "toggle")
        } else {
            startHold()
        }
    }

    /// Ends a recording left running (mouse unplugged, remapping switched off,
    /// the Mac going to sleep) so GVoice cannot keep recording with no way to
    /// stop it.
    func releaseHold() {
        guard isHolding else {
            return
        }
        stopHold(reason: "released-by-app")
    }

    private func startHold() {
        guard case .idle = holdState else {
            return
        }
        guard isReady else {
            // Nothing to record with. The click was let through as an ordinary
            // back-button click, so there is nothing to undo here.
            return
        }

        requestCounter += 1
        let requestID = "bo-\(requestCounter)"
        holdState = .starting(requestID: requestID, stopWhenAcked: false)
        Self.log.info("start \(requestID, privacy: .public)")
        send(["type": "start", "requestId": requestID])
        onStateChange?()
    }

    private func stopHold(reason: String) {
        switch holdState {
        case .idle:
            return
        case .starting(let requestID, _):
            // GVoice has not said yes yet. Remember to stop the moment it does.
            holdState = .starting(requestID: requestID, stopWhenAcked: true)
            Self.log.info("stop \(requestID, privacy: .public) queued (\(reason, privacy: .public))")
            return
        case .holding(let sessionID):
            holdState = .idle
            requestCounter += 1
            var message: [String: Any] = ["type": "stop", "requestId": "bo-\(requestCounter)"]
            if let sessionID {
                message["sessionId"] = sessionID
            }
            Self.log.info("stop \(sessionID ?? "unnamed", privacy: .public) (\(reason, privacy: .public))")
            send(message)
            onStateChange?()
        }
    }
}
