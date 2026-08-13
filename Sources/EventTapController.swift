import ApplicationServices
import CoreGraphics
import Foundation

final class EventTapController {
    typealias Callback = () -> Void

    private let deviceMonitor: HIDDeviceMonitor
    private let gvoiceIntegration: GVoiceIntegration

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onStateChange: Callback?
    var isEnabled = true

    init(deviceMonitor: HIDDeviceMonitor, gvoiceIntegration: GVoiceIntegration) {
        self.deviceMonitor = deviceMonitor
        self.gvoiceIntegration = gvoiceIntegration
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    var isTapInstalled: Bool {
        eventTap != nil
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard hasAccessibilityPermission else {
            onStateChange?()
            return
        }

        installTapIfNeeded()
        onStateChange?()
    }

    private func installTapIfNeeded() {
        guard eventTap == nil else {
            return
        }

        let mask =
            CGEventMask(1 << CGEventType.scrollWheel.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue) |
            CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: context
        ) else {
            onStateChange?()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown:
            return handlePotentialPTTMouseEvent(event, pressed: true)
        case .otherMouseUp:
            return handlePotentialPTTMouseEvent(event, pressed: false)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isEnabled, deviceMonitor.hasMatchedDevice else {
            return Unmanaged.passRetained(event)
        }

        let horizontalDelta = horizontalScrollDelta(for: event)
        guard horizontalDelta != 0 else {
            return Unmanaged.passRetained(event)
        }

        guard deviceMonitor.sawRecentThumbWheelEvent(within: 0.2) else {
            return Unmanaged.passRetained(event)
        }

        return nil
    }

    private func horizontalScrollDelta(for event: CGEvent) -> Int64 {
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if delta != 0 {
            return delta
        }

        let pointDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        if pointDelta != 0 {
            return pointDelta
        }

        let fixedPointDelta = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if fixedPointDelta != 0 {
            return fixedPointDelta
        }

        return 0
    }

    private func handlePotentialPTTMouseEvent(_ event: CGEvent, pressed: Bool) -> Unmanaged<CGEvent>? {
        guard isEnabled, deviceMonitor.hasMatchedDevice else {
            return Unmanaged.passRetained(event)
        }

        guard gvoiceIntegration.runningPID != nil else {
            return Unmanaged.passRetained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber >= 3 else {
            return Unmanaged.passRetained(event)
        }

        return deviceMonitor.sawRecentPTTButtonEvent(isPressed: pressed, within: 0.08)
            ? nil
            : Unmanaged.passRetained(event)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
        return controller.handle(type: type, event: event)
    }
}
