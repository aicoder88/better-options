import AppKit
import ApplicationServices

@MainActor
final class AppCoordinator: NSObject {
    private enum DefaultsKey {
        static let hasShownAccessibilityPrompt = "hasShownAccessibilityPrompt"
    }

    private let deviceMonitor = HIDDeviceMonitor()
    private let wisprIntegration = WisprIntegration()
    private let mediaKeySender = MediaKeySender()
    private lazy var eventTapController = EventTapController(
        deviceMonitor: deviceMonitor,
        wisprIntegration: wisprIntegration
    )

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var deviceStatusItem: NSMenuItem?
    private var remapToggleItem: NSMenuItem?
    private var permissionsItem: NSMenuItem?
    private var wisprItem: NSMenuItem?
    private var triggerItem: NSMenuItem?
    private var accessibilityPollingTimer: Timer?

    private var remappingEnabled = true {
        didSet {
            eventTapController.isEnabled = remappingEnabled
            updateMenu()
        }
    }

    func start() {
        buildMenu()
        wireCallbacks()

        wisprIntegration.refreshConfiguration()
        deviceMonitor.start()
        requestAccessibilityPermissionsIfNeeded()
        eventTapController.start()

        updateMenu()
    }

    private func wireCallbacks() {
        deviceMonitor.onStateChange = { [weak self] in
            self?.updateMenu()
        }

        deviceMonitor.onThumbWheelEvent = { [weak self] delta in
            guard let self, self.remappingEnabled else {
                return
            }

            if delta > 0 {
                self.mediaKeySender.sendVolumeDown()
            } else {
                self.mediaKeySender.sendVolumeUp()
            }
        }

        deviceMonitor.onPTTButtonEvent = { [weak self] pressed, _ in
            guard let self,
                  self.remappingEnabled,
                  self.wisprIntegration.runningPID != nil,
                  self.wisprIntegration.pttBindingState == .configured else {
                return
            }

            self.wisprIntegration.dispatchPTTEvent(pressed: pressed, location: .zero)
        }

        eventTapController.onStateChange = { [weak self] in
            self?.updateMenu()
        }

        wisprIntegration.onStateChange = { [weak self] in
            self?.updateMenu()
        }
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Options"
        statusItem = item

        let menu = NSMenu()
        statusMenu = menu

        let deviceStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        deviceStatusItem.isEnabled = false
        menu.addItem(deviceStatusItem)
        self.deviceStatusItem = deviceStatusItem

        let remapToggleItem = NSMenuItem(title: "", action: #selector(toggleRemapping), keyEquivalent: "")
        remapToggleItem.target = self
        menu.addItem(remapToggleItem)
        self.remapToggleItem = remapToggleItem

        let permissionsItem = NSMenuItem(title: "", action: #selector(requestAccessibilityPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        self.permissionsItem = permissionsItem

        let wisprItem = NSMenuItem(title: "", action: #selector(refreshWisprStatus), keyEquivalent: "")
        wisprItem.target = self
        menu.addItem(wisprItem)
        self.wisprItem = wisprItem

        let triggerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        triggerItem.isEnabled = false
        menu.addItem(triggerItem)
        self.triggerItem = triggerItem

        menu.addItem(.separator())

        let helpItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let quitItem = NSMenuItem(title: "Quit Better Options", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    private func updateMenu() {
        let accessibilityGranted = eventTapController.hasAccessibilityPermission
        let tapReady = eventTapController.isTapInstalled
        let deviceName = deviceMonitor.activeDeviceName ?? "No MX Master 3 detected"
        let statusPrefix = deviceMonitor.hasMatchedDevice ? "Device: " : "Waiting: "
        deviceStatusItem?.title = statusPrefix + deviceName

        remapToggleItem?.title = remappingEnabled ? "Disable Remapping" : "Enable Remapping"
        remapToggleItem?.isEnabled = accessibilityGranted && tapReady

        let inputMonitoring = deviceMonitor.hasInputMonitoring
        if accessibilityGranted && inputMonitoring {
            permissionsItem?.title = tapReady ? "Permissions: granted" : "Permissions: granted, tap unavailable"
        } else {
            var missing: [String] = []
            if !accessibilityGranted { missing.append("Accessibility") }
            if !inputMonitoring { missing.append("Input Monitoring") }
            permissionsItem?.title = "Grant: " + missing.joined(separator: ", ")
        }

        wisprItem?.title = wisprMenuTitle()
        triggerItem?.title = triggerMenuTitle()
        statusItem?.button?.title = summaryTitle(
            hasDevice: deviceMonitor.hasMatchedDevice,
            hasPermission: accessibilityGranted,
            wisprReady: wisprIntegration.pttBindingState == .configured
        )
    }

    private func wisprMenuTitle() -> String {
        switch wisprIntegration.pttBindingState {
        case .configured:
            return wisprIntegration.runningPID == nil ? "Wispr: PTT configured, app not running" : "Wispr: PTT configured"
        case .missingConfig:
            return "Wispr: config not found"
        case .bindingMismatch:
            return "Wispr: no supported PTT shortcut found"
        case .invalidConfig:
            return "Wispr: config unreadable"
        }
    }

    private func triggerMenuTitle() -> String {
        if let usage = deviceMonitor.lastObservedPTTButtonUsage {
            return "PTT trigger: MX button \(usage)"
        }
        return "PTT trigger: waiting for thumb-rest button"
    }

    private func summaryTitle(hasDevice: Bool, hasPermission: Bool, wisprReady: Bool) -> String {
        if !hasPermission {
            return "Options !"
        }
        if !hasDevice {
            return "Options ?"
        }
        return wisprReady ? "Options MX" : "Options MX!"
    }

    @objc
    private func toggleRemapping() {
        remappingEnabled.toggle()
    }

    @objc
    private func requestAccessibilityPermissions() {
        evaluateAccessibilityPermissions(promptIfNeeded: true)
    }

    private func requestAccessibilityPermissionsIfNeeded() {
        evaluateAccessibilityPermissions(promptIfNeeded: shouldPromptForAccessibilityOnLaunch())
    }

    private func beginAccessibilityPolling() {
        guard accessibilityPollingTimer == nil else {
            return
        }

        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }

                guard self.eventTapController.hasAccessibilityPermission else {
                    self.updateMenu()
                    return
                }

                timer.invalidate()
                self.accessibilityPollingTimer = nil
                self.eventTapController.start()
                self.updateMenu()
            }
        }
    }

    private func evaluateAccessibilityPermissions(promptIfNeeded: Bool) {
        if eventTapController.hasAccessibilityPermission {
            accessibilityPollingTimer?.invalidate()
            accessibilityPollingTimer = nil
            eventTapController.start()
            updateMenu()
            return
        }

        guard promptIfNeeded else {
            updateMenu()
            return
        }

        UserDefaults.standard.set(true, forKey: DefaultsKey.hasShownAccessibilityPrompt)
        _ = eventTapController.requestAccessibilityPermission()
        beginAccessibilityPolling()
        updateMenu()
    }

    private func shouldPromptForAccessibilityOnLaunch() -> Bool {
        !UserDefaults.standard.bool(forKey: DefaultsKey.hasShownAccessibilityPrompt)
    }

    @objc
    private func refreshWisprStatus() {
        wisprIntegration.refreshConfiguration()
        updateMenu()
    }

    @objc
    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
