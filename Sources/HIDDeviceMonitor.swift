import Foundation
import IOKit.hid

final class HIDDeviceMonitor {
    typealias Callback = () -> Void
    typealias PTTButtonCallback = (_ isPressed: Bool, _ usage: UInt32, _ deviceID: String) -> Void
    typealias ThumbWheelCallback = (_ delta: Int, _ deviceID: String) -> Void
    typealias ConsumerKeyCallback = (_ usage: UInt32, _ isPressed: Bool, _ deviceID: String) -> Void

    private let manager: IOHIDManager
    private let callbackQueue = DispatchQueue(label: "logiremap.hid-monitor")
    private let thumbWheelUsages: Set<UsageKey> = [
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPan)),
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPanLeft)),
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPanRight)),
    ]
    private let pttCandidateButtonUsages = Set(UInt32(6)...UInt32(16))
    /// The function-row keys worth reporting. Anything else the keyboard sends
    /// is left alone rather than routed through the remap.
    private let keyboardConsumerUsages = Set(ConsumerKey.selectable)

    private var trackedDevices: [OpaquePointer: DeviceInfo] = [:]
    private let lock = NSLock()
    private var lastThumbWheelEventAt: UInt64 = 0
    private var lastPTTDownAt: UInt64 = 0
    private var lastPTTUpAt: UInt64 = 0
    private var lastObservedPTTUsage: UInt32?
    private var lastConsumerKeyEventAt: UInt64 = 0
    private var lastConsumerKeyUsage: UInt32?

    var onStateChange: Callback?
    var onPTTButtonEvent: PTTButtonCallback?
    var onThumbWheelEvent: ThumbWheelCallback?
    var onConsumerKeyEvent: ConsumerKeyCallback?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var hasMatchedDevice: Bool {
        lock.withLock {
            !trackedDevices.isEmpty
        }
    }

    var activeDeviceName: String? {
        lock.withLock {
            trackedDevices.values.first?.productName
        }
    }

    /// Every device plugged in right now that this app knows how to remap,
    /// named by model rather than by the Mac's longer product name.
    ///
    /// Bindings are saved against the model, because the file already on disk
    /// keys them on `mx-master-3`. Using the full product name instead would
    /// leave every one of those bindings pointing at a device that never turns
    /// up.
    var connectedKnownDevices: [KnownDevice] {
        let devices = lock.withLock {
            trackedDevices.values.map(\.known)
        }

        // One physical device shows up several times, once per interface it
        // exposes.
        return KnownDevice.all.filter(devices.contains)
    }

    /// The model of the mouse in use, e.g. `MX Master 3`.
    var activeDeviceModel: String? {
        connectedKnownDevices.first(where: { $0.type == .mouse })?.model
    }

    /// The names to show in the menu, e.g. `MX Master 3, MX Keys S`.
    var activeDeviceDisplayName: String? {
        let models = connectedKnownDevices.map(\.model)
        return models.isEmpty ? nil : models.joined(separator: ", ")
    }

    var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func start() {
        let matching: [[String: Any]] = [[
            kIOHIDVendorIDKey as String: 0x046D,
        ]]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.handleDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.handleDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, Self.handleInputValue, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes!.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        if !hasInputMonitoring {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        if let currentDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in currentDevices {
                registerIfRelevant(device)
            }
        }
    }

    func sawRecentThumbWheelEvent(within seconds: TimeInterval) -> Bool {
        recentEvent(lastThumbWheelEventAt, within: seconds)
    }

    func sawRecentPTTButtonEvent(isPressed: Bool, within seconds: TimeInterval) -> Bool {
        recentEvent(isPressed ? lastPTTDownAt : lastPTTUpAt, within: seconds)
    }

    var lastObservedPTTButtonUsage: UInt32? {
        lock.withLock {
            lastObservedPTTUsage
        }
    }

    private func recentEvent(_ timestamp: UInt64, within seconds: TimeInterval) -> Bool {
        guard timestamp > 0 else {
            return false
        }

        let window = UInt64(seconds * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &- timestamp <= window
    }

    private func registerIfRelevant(_ device: IOHIDDevice) {
        guard let productName = propertyString(kIOHIDProductKey, device: device),
              let known = KnownDevice.matching(productName: productName) else {
            return
        }

        let info = DeviceInfo(
            productName: productName,
            known: known,
            vendorID: propertyInt(kIOHIDVendorIDKey, device: device),
            productID: propertyInt(kIOHIDProductIDKey, device: device)
        )

        let key = OpaquePointer(Unmanaged.passUnretained(device).toOpaque())
        let wasInserted: Bool = lock.withLock {
            trackedDevices.updateValue(info, forKey: key) == nil
        }

        if wasInserted {
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes!.rawValue)
            IOHIDDeviceRegisterInputValueCallback(device, Self.handleInputValue, context)
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?()
            }
        }
    }

    private func remove(_ device: IOHIDDevice) {
        let key = OpaquePointer(Unmanaged.passUnretained(device).toOpaque())
        let removed = lock.withLock {
            trackedDevices.removeValue(forKey: key) != nil
        }

        if removed {
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?()
            }
        }
    }

    private func recordInput(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let deviceKey = OpaquePointer(Unmanaged.passUnretained(device).toOpaque())
        // Which device sent this, not just what kind it is: the binding that
        // fires has to be the one saved for the device the hand was on.
        let known: KnownDevice? = lock.withLock {
            trackedDevices[deviceKey]?.known
        }
        guard let known else {
            return
        }

        let deviceType = known.type
        let deviceID = known.id

        let usage = UsageKey(
            page: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element)
        )
        let integerValue = IOHIDValueGetIntegerValue(value)
        let now = DispatchTime.now().uptimeNanoseconds

        var thumbWheelDelta: Int?
        var shouldDispatchPTT = false
        var pttUsage: UInt32?
        var consumerKeyUsage: UInt32?

        lock.withLock {
            switch deviceType {
            case .keyboard:
                // The keyboard's own wheel-like controls share usage numbers
                // with the mouse's, so only the function row is read here.
                guard usage.page == UInt32(kHIDPage_Consumer),
                      keyboardConsumerUsages.contains(usage.usage) else {
                    return
                }

                lastConsumerKeyEventAt = now
                lastConsumerKeyUsage = usage.usage
                consumerKeyUsage = usage.usage

            case .mouse:
                if thumbWheelUsages.contains(usage), integerValue != 0 {
                    lastThumbWheelEventAt = now
                    thumbWheelDelta = integerValue
                } else if usage.page == UInt32(kHIDPage_Button), pttCandidateButtonUsages.contains(usage.usage) {
                    lastObservedPTTUsage = usage.usage
                    if integerValue == 0 {
                        lastPTTUpAt = now
                    } else {
                        lastPTTDownAt = now
                    }
                    shouldDispatchPTT = true
                    pttUsage = usage.usage
                }
            }
        }

        if let thumbWheelDelta {
            DispatchQueue.main.async { [weak self] in
                self?.onThumbWheelEvent?(thumbWheelDelta, deviceID)
            }
        }

        if shouldDispatchPTT, let pttUsage {
            DispatchQueue.main.async { [weak self] in
                self?.onPTTButtonEvent?(integerValue != 0, pttUsage, deviceID)
                self?.onStateChange?()
            }
        }

        if let consumerKeyUsage {
            DispatchQueue.main.async { [weak self] in
                self?.onConsumerKeyEvent?(consumerKeyUsage, integerValue != 0, deviceID)
            }
        }
    }

    /// Whether the keyboard just sent this key, so the Mac's own copy of the
    /// keypress can be swallowed instead of firing on top of the remap.
    func sawRecentConsumerKey(_ usage: UInt32, within seconds: TimeInterval) -> Bool {
        // Both halves are read together: the key and the moment it arrived have
        // to describe the same press, and a press on another key can land
        // between two reads.
        let (matches, timestamp) = lock.withLock {
            (lastConsumerKeyUsage == usage, lastConsumerKeyEventAt)
        }

        return matches && recentEvent(timestamp, within: seconds)
    }

    private func propertyString(_ key: String, device: IOHIDDevice) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }
        return value as? String
    }

    private func propertyInt(_ key: String, device: IOHIDDevice) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private static let handleDeviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.registerIfRelevant(device)
    }

    private static let handleDeviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.remove(device)
    }

    private static let handleInputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }

        let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.recordInput(value: value)
    }
}

private struct DeviceInfo {
    let productName: String
    let known: KnownDevice
    let vendorID: Int?
    let productID: Int?
}

private struct UsageKey: Hashable {
    let page: UInt32
    let usage: UInt32
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
