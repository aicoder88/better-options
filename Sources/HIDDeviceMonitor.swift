import Foundation
import IOKit.hid

final class HIDDeviceMonitor {
    typealias Callback = () -> Void
    typealias PTTButtonCallback = (_ isPressed: Bool, _ usage: UInt32) -> Void
    typealias ThumbWheelCallback = (_ delta: Int) -> Void

    private let manager: IOHIDManager
    private let callbackQueue = DispatchQueue(label: "logiremap.hid-monitor")
    private let acceptedNamePrefixes = [
        "MX Master 3",
    ]
    private let thumbWheelUsages: Set<UsageKey> = [
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPan)),
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPanLeft)),
        UsageKey(page: UInt32(kHIDPage_Consumer), usage: UInt32(kHIDUsage_Csmr_ACPanRight)),
    ]
    private let pttCandidateButtonUsages = Set(UInt32(6)...UInt32(16))

    private var trackedDevices: [OpaquePointer: DeviceInfo] = [:]
    private let lock = NSLock()
    private var lastThumbWheelEventAt: UInt64 = 0
    private var lastPTTDownAt: UInt64 = 0
    private var lastPTTUpAt: UInt64 = 0
    private var lastObservedPTTUsage: UInt32?

    var onStateChange: Callback?
    var onPTTButtonEvent: PTTButtonCallback?
    var onThumbWheelEvent: ThumbWheelCallback?

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
              matchesAcceptedProduct(productName) else {
            return
        }

        let info = DeviceInfo(
            productName: productName,
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

    private func matchesAcceptedProduct(_ productName: String) -> Bool {
        acceptedNamePrefixes.contains(where: { productName.hasPrefix($0) })
    }

    private func recordInput(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let deviceKey = OpaquePointer(Unmanaged.passUnretained(device).toOpaque())
        let isTracked = lock.withLock {
            trackedDevices[deviceKey] != nil
        }
        guard isTracked else {
            return
        }

        let usage = UsageKey(
            page: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element)
        )
        let integerValue = IOHIDValueGetIntegerValue(value)
        let now = DispatchTime.now().uptimeNanoseconds

        var thumbWheelDelta: Int?
        var shouldDispatchPTT = false
        var pttUsage: UInt32?

        lock.withLock {
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

        if let thumbWheelDelta {
            DispatchQueue.main.async { [weak self] in
                self?.onThumbWheelEvent?(thumbWheelDelta)
            }
        }

        if shouldDispatchPTT, let pttUsage {
            DispatchQueue.main.async { [weak self] in
                self?.onPTTButtonEvent?(integerValue != 0, pttUsage)
                self?.onStateChange?()
            }
        }
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
