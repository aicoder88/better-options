import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class EventTapController {
    typealias Callback = () -> Void

    private let deviceMonitor: HIDDeviceMonitor

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onStateChange: Callback?
    var isEnabled = true

    /// Asked before swallowing a side-button press: true means "something is
    /// bound to it and ready to run, take the event instead of letting it
    /// through as a browser-back click." The caller decides what "ready"
    /// means per action (GVoice only says yes while it's actually running).
    var shouldHandleSideButton: (() -> Bool)?

    /// Asked before swallowing a function-row key on the keyboard: true means
    /// that key has been pointed at something other than what it is printed
    /// with, so the Mac's own copy of the press must not fire on top of it.
    var shouldHandleConsumerKey: ((UInt32) -> Bool)?

    init(deviceMonitor: HIDDeviceMonitor) {
        self.deviceMonitor = deviceMonitor
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
            CGEventMask(1 << Self.systemDefinedEventType) |
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
            guard type.rawValue == Self.systemDefinedEventType else {
                return Unmanaged.passRetained(event)
            }
            return handlePotentialConsumerKeyEvent(event)
        }
    }

    /// The media keys arrive as this kind of event, which `CGEventType` has no
    /// name for.
    private static let systemDefinedEventType: UInt32 = 14
    /// Within a system-defined event, the one flavour that means a media key.
    private static let mediaKeySubtype = 8

    /// Swallows a function-row key only when it has been pointed somewhere
    /// else and the keyboard itself just sent it. Anything else — another
    /// keyboard, an unbound key, the remap switched off — goes through
    /// untouched, so the keys keep doing what they are printed with.
    private func handlePotentialConsumerKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isEnabled,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.mediaKeySubtype else {
            return Unmanaged.passRetained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        guard let usage = ConsumerKey.usage(forSystemKeyCode: keyCode),
              shouldHandleConsumerKey?(usage) ?? false,
              deviceMonitor.sawRecentConsumerKey(usage, within: 0.2) else {
            return Unmanaged.passRetained(event)
        }

        return nil
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

        guard shouldHandleSideButton?() ?? false else {
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
