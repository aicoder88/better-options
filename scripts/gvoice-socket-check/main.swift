import Foundation

// Proves Better Options really talks to GVoice over the local socket: it says
// hello, keeps saying it is alive, asks for a recording when the button goes
// down, ends it when the button comes up, and stops offering dictation the
// moment GVoice hangs up.
//
// A stand-in GVoice runs inside this program, so nothing here touches the real
// dictation app, the real microphone, or the real socket. The one thing it
// cannot do is press a physical mouse button; that stays a hand check.

// MARK: - A stand-in GVoice on a unix socket

final class FakeGVoice {
    let path: String

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private var seen: [String] = []
    private let readyToRecord = true

    init(path: String) {
        self.path = path
    }

    var received: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw Failure("could not make a socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure("socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw Failure("could not bind \(path): \(String(cString: strerror(errno)))")
        }
        guard listen(listenFD, 4) == 0 else {
            throw Failure("could not listen on \(path)")
        }

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Hangs up on the client, the way a GVoice that quits does.
    func hangUp() {
        lock.lock()
        let fd = clientFD
        clientFD = -1
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
    }

    func stop() {
        hangUp()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                return
            }
            lock.lock()
            clientFD = fd
            lock.unlock()
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                return
            }
            buffer.append(contentsOf: chunk[0..<count])

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                handle(line: line, fd: fd)
            }
        }
    }

    private func handle(line: Data, fd: Int32) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        lock.lock()
        seen.append(type)
        let ready = readyToRecord
        lock.unlock()

        let requestID = (object["requestId"] as? String) ?? ""

        switch type {
        case "hello", "heartbeat":
            send(#"{"type":"status","version":1,"ready":\#(ready),"micMode":"always","session":null}"#, to: fd)
        case "start":
            send(#"{"type":"ack","requestId":"\#(requestID)","sessionId":"session-1"}"#, to: fd)
        case "stop", "cancel":
            send(#"{"type":"ack","requestId":"\#(requestID)","sessionId":"session-1"}"#, to: fd)
        default:
            break
        }
    }

    private func send(_ text: String, to fd: Int32) {
        let payload = Array((text + "\n").utf8)
        _ = payload.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Helpers

/// Runs the main run loop until `condition` comes true, or gives up.
func waitFor(_ what: String, timeout: TimeInterval = 6, condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    throw Failure("timed out waiting for \(what)")
}

func check(_ passed: Bool, _ what: String) throws {
    guard passed else {
        throw Failure(what)
    }
    print("  ok: \(what)")
}

// MARK: - The check itself

let socketPath = ProcessInfo.processInfo.environment["BETTEROPTIONS_GVOICE_SOCKET"] ?? ""
guard !socketPath.isEmpty else {
    FileHandle.standardError.write(Data("BETTEROPTIONS_GVOICE_SOCKET is not set\n".utf8))
    exit(2)
}

let server = FakeGVoice(path: socketPath)
let integration = GVoiceIntegration()

do {
    try server.start()
    print("stand-in GVoice listening on \(socketPath)")

    integration.refreshConfiguration()

    try check(integration.isRunning, "the real GVoice is running, so the companion tries to connect")
    try waitFor("the handshake") { integration.isReady }
    try check(server.received.contains("hello"), "said hello")
    try check(integration.connectionState == .connected, "the menu would read: ready")

    // Button down.
    integration.dispatchPTTEvent(pressed: true)
    try waitFor("the recording to start") { server.received.contains("start") }
    try check(integration.isHolding, "holding while the button is down")

    // Button up.
    integration.dispatchPTTEvent(pressed: false)
    try waitFor("the recording to stop") { server.received.contains("stop") }
    try check(!integration.isHolding, "not holding once the button is up")

    // The heartbeat is what stops GVoice ending a recording on its own.
    try waitFor("a heartbeat", timeout: 5) { server.received.contains("heartbeat") }
    try check(true, "kept the heartbeat going")

    // GVoice quits mid-conversation.
    server.hangUp()
    try waitFor("dictation to stop being offered") { !integration.isReady }
    try check(!integration.isReady, "the side button passes through once GVoice hangs up")

    server.stop()
    print("PASS")
    exit(0)
} catch {
    server.stop()
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
