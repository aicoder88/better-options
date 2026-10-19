import Foundation
import IOKit.hid
import os

/// The gesture button under the thumb, taken over through Logitech's own
/// HID++ channel.
///
/// Left alone, the mouse answers that button by typing Cmd+Tab itself, all in
/// one instant on press, so there is no hold and no release to time anything
/// by. HID++ lets the button be "diverted": the mouse stops typing anything and
/// reports the button going down and coming up instead, which is what
/// Logi Options+ does. A diverted button does nothing else, so it is only
/// diverted while something is bound to it, and handed back otherwise.
///
/// The mouse forgets the diversion whenever it reconnects or wakes from a deep
/// sleep, so it is sent again on every connect and after any quiet spell.
@MainActor
final class ThumbButtonDiverter {
    typealias PressCallback = (_ isPressed: Bool, _ deviceID: String) -> Void

    var onPress: PressCallback?

    /// Whether the button should report holds. Setting it sends the change to
    /// every connected mouse.
    var isWanted = false {
        didSet {
            guard isWanted != oldValue else {
                return
            }
            for device in devices.values {
                sendReporting(device)
            }
        }
    }

    private static let log = Logger(subsystem: "com.purr.betteroptions", category: "thumb")
    /// HID++ 2.0 feature that remaps a mouse's own controls.
    private static let reprogControlsFeature: [UInt8] = [0x1B, 0x04]
    /// The gesture button's control number on the MX Master 3.
    private static let gestureButton: [UInt8] = [0x00, 0xC3]
    private static let longReportID: UInt8 = 0x11
    /// A Bluetooth mouse answers on device number 0xFF.
    private static let deviceIndex: UInt8 = 0xFF
    /// Our replies are told apart from the mouse's own notifications by this.
    private static let softwareID: UInt8 = 0x0A
    /// A mouse that has said nothing for this long may have slept and dropped
    /// the diversion.
    private static let quietSpell: TimeInterval = 30

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices: [OpaquePointer: MouseState] = [:]

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.handleMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.handleRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes!.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Hands the button back to the mouse, so it types Cmd+Tab again.
    func stop() {
        isWanted = false
    }

    private func add(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        guard let known = KnownDevice.matching(productName: name), known.type == .mouse else {
            return
        }

        let key = Self.key(device)
        guard devices[key] == nil else {
            return
        }

        let state = MouseState(device: device, deviceID: known.id)
        devices[key] = state
        IOHIDDeviceRegisterInputReportCallback(
            device,
            state.buffer,
            state.bufferSize,
            Self.handleReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes!.rawValue)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        askForFeatureIndex(state)
    }

    private func remove(_ device: IOHIDDevice) {
        guard let state = devices.removeValue(forKey: Self.key(device)) else {
            return
        }
        // Nothing will ever say this button came up.
        if state.isPressed {
            onPress?(false, state.deviceID)
        }
    }

    private func askForFeatureIndex(_ state: MouseState) {
        send(state, feature: 0x00, function: 0, params: Self.reprogControlsFeature)
    }

    private func sendReporting(_ state: MouseState) {
        guard let index = state.featureIndex else {
            return
        }
        // Bit 0 diverts, bit 1 says bit 0 is meant.
        let flags: UInt8 = isWanted ? 0x03 : 0x02
        send(state, feature: index, function: 3, params: Self.gestureButton + [flags])
        if !isWanted, state.isPressed {
            state.isPressed = false
            onPress?(false, state.deviceID)
        }
    }

    private func send(_ state: MouseState, feature: UInt8, function: UInt8, params: [UInt8]) {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = Self.longReportID
        report[1] = Self.deviceIndex
        report[2] = feature
        report[3] = (function << 4) | Self.softwareID
        report.replaceSubrange(4..<(4 + params.count), with: params)
        let result = IOHIDDeviceSetReport(
            state.device,
            kIOHIDReportTypeOutput,
            CFIndex(Self.longReportID),
            report,
            report.count
        )
        if result != kIOReturnSuccess {
            Self.log.error("HID++ send failed: \(result, privacy: .public)")
        }
    }

    private func handle(report: [UInt8], from device: IOHIDDevice) {
        guard let state = devices[Self.key(device)] else {
            return
        }

        let now = Date()
        let wasQuiet = now.timeIntervalSince(state.lastHeardAt) > Self.quietSpell
        state.lastHeardAt = now

        guard report.count >= 8, report[0] == Self.longReportID else {
            if wasQuiet, isWanted {
                sendReporting(state)
            }
            return
        }

        // The root feature's answer: where the remap feature lives.
        if report[2] == 0x00, report[3] == Self.softwareID {
            state.featureIndex = report[4] == 0 ? nil : report[4]
            Self.log.info("thumb button feature index \(report[4], privacy: .public)")
            sendReporting(state)
            return
        }

        // A notification from the remap feature: the diverted controls held
        // down right now, two bytes each, zeros when none are.
        guard let index = state.featureIndex, report[2] == index, report[3] == 0x00 else {
            return
        }

        let held = stride(from: 4, to: min(report.count, 12), by: 2).contains {
            report[$0] == Self.gestureButton[0] && report[$0 + 1] == Self.gestureButton[1]
        }
        guard held != state.isPressed else {
            return
        }
        state.isPressed = held
        onPress?(held, state.deviceID)
    }

    private static func key(_ device: IOHIDDevice) -> OpaquePointer {
        OpaquePointer(Unmanaged.passUnretained(device).toOpaque())
    }

    private static let handleMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }
        MainActor.assumeIsolated {
            Unmanaged<ThumbButtonDiverter>.fromOpaque(context).takeUnretainedValue().add(device)
        }
    }

    private static let handleRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }
        MainActor.assumeIsolated {
            Unmanaged<ThumbButtonDiverter>.fromOpaque(context).takeUnretainedValue().remove(device)
        }
    }

    private static let handleReport: IOHIDReportCallback = { context, _, sender, _, _, report, length in
        guard let context, let sender else {
            return
        }
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        MainActor.assumeIsolated {
            Unmanaged<ThumbButtonDiverter>.fromOpaque(context).takeUnretainedValue()
                .handle(report: bytes, from: device)
        }
    }
}

private final class MouseState {
    let device: IOHIDDevice
    let deviceID: String
    let bufferSize = 64
    let buffer: UnsafeMutablePointer<UInt8>
    var featureIndex: UInt8?
    var isPressed = false
    var lastHeardAt = Date()

    init(device: IOHIDDevice, deviceID: String) {
        self.device = device
        self.deviceID = deviceID
        buffer = .allocate(capacity: bufferSize)
    }

    deinit {
        buffer.deallocate()
    }
}
