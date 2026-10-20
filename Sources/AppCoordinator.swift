import AppKit
import ApplicationServices

@MainActor
final class AppCoordinator: NSObject {
    private enum DefaultsKey {
        static let hasShownAccessibilityPrompt = "hasShownAccessibilityPrompt"
    }

    private let deviceMonitor = HIDDeviceMonitor()
    private let deviceRegistry = DeviceRegistry()
    private let handy = HandyIntegration()
    private let thumbButton = ThumbButtonDiverter()
    private let mediaKeySender = MediaKeySender()
    private let settingsStore = SettingsStore()
    private let volumeHUDController = VolumeHUDController()
    private let wheelCoalescer = WheelCoalescer()
    private lazy var systemActionSender = SystemActionSender(mediaKeySender: mediaKeySender)
    private lazy var eventTapController = EventTapController(deviceMonitor: deviceMonitor)
    private lazy var settingsWindowController = SettingsWindowController(
        store: settingsStore,
        deviceRegistry: deviceRegistry
    )

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var deviceStatusItem: NSMenuItem?
    private var remapToggleItem: NSMenuItem?
    private var permissionsItem: NSMenuItem?
    private var handyItem: NSMenuItem?
    private var volumePreviewItem: NSMenuItem?
    private var accessibilitySettingsItem: NSMenuItem?
    private var accessibilityPollingTimer: Timer?
    /// Which control on which device is holding dictation down right now. Only
    /// that control's release ends the hold, and the hold is let go of when
    /// that device goes away.
    private var holdingTrigger: Trigger?
    private var holdingDeviceID: String?
    private var systemObservers: [NSObjectProtocol] = []
    /// A settings file that cannot be written says so once. Saying it on every
    /// keystroke of a settings window would be worse than saying nothing.
    private var hasReportedSaveFailure = false

    private var remappingEnabled = true {
        didSet {
            guard remappingEnabled != oldValue else {
                return
            }

            eventTapController.isEnabled = remappingEnabled
            if !remappingEnabled {
                releaseHeldControls()
            }
            // Switching it off has to survive a quit, or the next launch turns
            // it back on behind the user's back.
            settingsStore.isEnabled = remappingEnabled
            updateMenu()
        }
    }

    func start() {
        settingsStore.load()

        buildMenu()
        wireCallbacks()
        observeSystemEvents()

        // What the file says, not what this line was born with.
        remappingEnabled = settingsStore.isEnabled
        eventTapController.isEnabled = remappingEnabled

        handy.refreshConfiguration()
        deviceMonitor.start()
        thumbButton.start()
        requestAccessibilityPermissionsIfNeeded()
        eventTapController.start()

        updateMenu()
    }

    /// Lets go of anything being held down — dictation above all.
    ///
    /// A hold that is never released leaves Handy recording with nothing left
    /// to stop it, so every way out of a hold ends here: the mouse unplugged,
    /// the binding changed, remapping switched off, the Mac going to sleep,
    /// the app quitting.
    func releaseHeldControls() {
        holdingTrigger = nil
        holdingDeviceID = nil
        wheelCoalescer.reset()
        handy.releaseHold()
    }

    /// The Mac going to sleep or shutting down never sends a button release, so
    /// a hold that is up when the screen goes dark would still be up when it
    /// comes back.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.willPowerOffNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]

        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releaseHeldControls()
                }
            }
            systemObservers.append(token)
        }

        // A mouse that slept along with the Mac may have dropped the thumb
        // button; ask for it back now rather than at the next half minute.
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.thumbButton.resend()
            }
        }
        systemObservers.append(wake)
    }

    /// The device that started a hold has been unplugged: nothing is ever going
    /// to send the release, so send it here.
    private func releaseHeldControlsIfDeviceGone() {
        guard handy.isHolding else {
            return
        }

        let connected = Set(deviceMonitor.connectedKnownDevices.map(\.id))
        let stillPluggedIn = holdingDeviceID.map(connected.contains) ?? false

        if !stillPluggedIn {
            releaseHeldControls()
        }
    }

    /// The control being held has just been pointed at something else, so the
    /// release that was coming would go to the new action instead.
    private func releaseHeldControlsIfUnbound() {
        guard handy.isHolding, let holdingTrigger, let holdingDeviceID else {
            return
        }

        if !settingsStore.action(for: holdingTrigger, deviceID: holdingDeviceID).isPushToTalk {
            releaseHeldControls()
        }
    }

    private func wireCallbacks() {
        deviceMonitor.onStateChange = { [weak self] in
            self?.syncDeviceRegistry()
            self?.releaseHeldControlsIfDeviceGone()
            self?.updateMenu()
        }

        settingsStore.onChange = { [weak self] in
            self?.releaseHeldControlsIfUnbound()
            self?.updateMenu()
        }

        deviceMonitor.onThumbWheelEvent = { [weak self] delta, deviceID in
            guard let self, self.remappingEnabled else {
                return
            }

            self.handleWheelTick(direction: delta > 0 ? .right : .left, deviceID: deviceID)
        }

        wheelCoalescer.scheduleFlush = { [weak self] in
            // Long enough to gather one flick, short enough that the volume
            // still moves the moment the wheel does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated {
                    self?.wheelCoalescer.flush()
                }
            }
        }

        wheelCoalescer.onBatch = { [weak self] batch in
            MainActor.assumeIsolated {
                self?.fireWheelBatch(batch)
            }
        }

        settingsStore.onSaveFailure = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reportSettingsSaveFailure(message)
                }
            }
        }

        deviceMonitor.onPTTButtonEvent = { [weak self] pressed, _, deviceID in
            guard let self, self.remappingEnabled else {
                return
            }
            // The click already went through to the apps (it beat the mouse's
            // own report), so the button has done its one thing.
            if pressed, self.eventTapController.sideButtonPressReachedApps {
                return
            }

            self.fireHoldTrigger(.sideButton, pressed: pressed, deviceID: deviceID)
        }

        thumbButton.onPress = { [weak self] pressed, deviceID in
            // A release always goes through, so switching the remap off
            // mid-hold cannot leave Handy recording.
            guard let self, self.remappingEnabled || !pressed else {
                return
            }

            self.fireHoldTrigger(.thumbButton, pressed: pressed, deviceID: deviceID)
        }

        deviceMonitor.onConsumerKeyEvent = { [weak self] usage, pressed, deviceID in
            // Fires once, when the key goes down, the way a media key does.
            guard let self, self.remappingEnabled, pressed else {
                return
            }

            self.fireMomentaryTrigger(.consumerKey(usage), deviceID: deviceID)
        }

        eventTapController.shouldHandleConsumerKey = { [weak self] usage in
            guard let self else {
                return false
            }

            return self.keyboardAction(for: usage).isSupported
        }

        eventTapController.shouldHandleThumbWheel = { [weak self] in
            guard let self else {
                return false
            }

            let deviceID = self.currentDeviceID()
            return [Trigger.thumbWheelLeft, .thumbWheelRight].contains {
                self.settingsStore.action(for: $0, deviceID: deviceID).isSupported
            }
        }

        eventTapController.shouldHandleSideButton = { [weak self] in
            guard let self else {
                return false
            }

            let sideButtonAction = self.action(for: .sideButton)
            guard sideButtonAction.isSupported else {
                return false
            }
            if sideButtonAction.isPushToTalk {
                // Only takes the click while Handy is open. Otherwise the click
                // goes through as the ordinary back-button click it is printed with.
                return self.handy.isReady
            }
            return true
        }

        eventTapController.onStateChange = { [weak self] in
            self?.updateMenu()
        }

        handy.onStateChange = { [weak self] in
            self?.updateMenu()
        }
    }

    private func currentDeviceID() -> String {
        deviceRegistry.activeDevice?.id ?? settingsStore.defaultDeviceID
    }

    private func currentKeyboardID() -> String {
        deviceRegistry.activeKeyboard?.id ?? settingsStore.defaultKeyboardID
    }

    private func action(for trigger: Trigger) -> Action {
        settingsStore.action(for: trigger, deviceID: currentDeviceID())
    }

    private func keyboardAction(for usage: UInt32) -> Action {
        settingsStore.action(for: .consumerKey(usage), deviceID: currentKeyboardID())
    }

    /// Fires whatever a tap-like control is bound to — a wheel tick or a key
    /// on the function row. Handy PTT toggles here instead of holding, since
    /// a tap has no separate release to end the hold on.
    private func fireMomentaryTrigger(_ trigger: Trigger, deviceID: String? = nil) {
        let bindingDeviceID = deviceID ?? currentDeviceID()
        let action = settingsStore.action(for: trigger, deviceID: bindingDeviceID)

        if action.isPushToTalk {
            guard handy.isReady else {
                return
            }
            handy.togglePTT()
            holdingTrigger = handy.isHolding ? trigger : nil
            holdingDeviceID = handy.isHolding ? bindingDeviceID : nil
            return
        }

        if let volume = systemActionSender.perform(action) {
            volumeHUDController.show(volume: volume)
        }
    }

    /// One tick of the thumb wheel.
    ///
    /// Dictation is never held back for a moment: waiting for the flick to
    /// finish would mean the microphone opening late. Everything else is
    /// gathered up so one flick moves the volume once and draws the volume
    /// window once.
    private func handleWheelTick(direction: WheelCoalescer.Direction, deviceID: String) {
        let trigger = wheelTrigger(for: direction)

        if settingsStore.action(for: trigger, deviceID: deviceID).isPushToTalk {
            wheelCoalescer.reset()
            fireMomentaryTrigger(trigger, deviceID: deviceID)
            return
        }

        wheelCoalescer.sensitivity = settingsStore.wheelSensitivity
        wheelCoalescer.add(direction: direction, deviceID: deviceID)
    }

    /// Which saved binding a way of the wheel reads, with the swap applied.
    private func wheelTrigger(for direction: WheelCoalescer.Direction) -> Trigger {
        let swapped = settingsStore.reverseWheel

        switch direction {
        case .right:
            return swapped ? .thumbWheelLeft : .thumbWheelRight
        case .left:
            return swapped ? .thumbWheelRight : .thumbWheelLeft
        }
    }

    /// A whole flick of the wheel: the action fires once per step, and the
    /// volume window is drawn once, showing where the volume ended up.
    private func fireWheelBatch(_ batch: WheelCoalescer.Batch) {
        let action = settingsStore.action(for: wheelTrigger(for: batch.direction), deviceID: batch.deviceID)

        guard action.isSupported, !action.isPushToTalk else {
            return
        }

        // A second Cmd+Tab goes straight back, so a flick switches apps once.
        let steps = action == .previousApp ? 1 : batch.steps
        var volume: Float?
        for _ in 0..<steps {
            volume = systemActionSender.perform(action) ?? volume
        }

        if let volume {
            volumeHUDController.show(volume: volume)
        }
    }

    /// The settings file could not be written.
    ///
    /// The store has already put memory back to what is on disk, so the menu is
    /// rebuilt to match it and the person is told once, plainly, that the change
    /// did not stick.
    private func reportSettingsSaveFailure(_ message: String) {
        if remappingEnabled != settingsStore.isEnabled {
            remappingEnabled = settingsStore.isEnabled
        }
        updateMenu()

        guard !hasReportedSaveFailure else {
            return
        }
        hasReportedSaveFailure = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Better Options could not save your settings"
        alert.informativeText = """
        Your change was undone, because it could not be written to \
        \(settingsStore.fileURL.path).

        \(message)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Fires whatever a held button (the side button or the thumb button) is
    /// bound to. Handy PTT holds for exactly as long as the button is down,
    /// same as it always has; any other action fires once, on press.
    private func fireHoldTrigger(_ trigger: Trigger, pressed: Bool, deviceID: String) {
        // Only the control that began a hold ends it, and it always does, even
        // if Handy just quit or the control was rebound mid-hold: otherwise the
        // recording never ends, or a second dictation button cuts it short.
        guard pressed else {
            if holdingTrigger == trigger {
                holdingTrigger = nil
                holdingDeviceID = nil
                handy.releaseHold()
            }
            return
        }

        let buttonAction = settingsStore.action(for: trigger, deviceID: deviceID)

        guard buttonAction.isPushToTalk else {
            if let volume = systemActionSender.perform(buttonAction) {
                volumeHUDController.show(volume: volume)
            }
            return
        }

        // A hold already running belongs to whichever control started it.
        guard handy.isReady, !handy.isHolding else {
            return
        }

        handy.dispatchPTTEvent(pressed: true)
        if handy.isHolding {
            holdingTrigger = trigger
            holdingDeviceID = deviceID
        }
    }

    /// The menu bar icon: a keyboard with a mouse beside it, overlapping.
    ///
    /// Both symbols are drawn into one image, which is what 0.2 did and why it
    /// reached for the drawing calls at all. The picture is the point — this
    /// app remaps a keyboard and a mouse, and the icon says so at a glance.
    /// Marked as a template so macOS colours it to suit a light or dark menu
    /// bar rather than it being painted one fixed colour.
    private static func menuBarIcon() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let keyboard = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
              let mouse = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }

        // The mouse sits to the right and slightly taller than the keyboard,
        // overlapping its edge, so the pair reads as one mark rather than two
        // icons that happen to be next to each other.
        let keyboardSize = NSSize(width: 15, height: 10)
        let mouseSize = NSSize(width: 7, height: 12)
        let overlap: CGFloat = 2
        let size = NSSize(
            width: keyboardSize.width + mouseSize.width - overlap,
            height: mouseSize.height
        )

        let icon = NSImage(size: size)
        icon.lockFocus()
        keyboard.draw(in: NSRect(
            x: 0,
            y: (size.height - keyboardSize.height) / 2,
            width: keyboardSize.width,
            height: keyboardSize.height
        ))
        mouse.draw(in: NSRect(
            x: size.width - mouseSize.width,
            y: 0,
            width: mouseSize.width,
            height: mouseSize.height
        ))
        icon.unlockFocus()
        icon.isTemplate = true

        return icon
    }

    private func buildMenu() {
        // A fixed square slot, the width 0.2 took. Left to size itself the
        // slot grows with the icon and shoves everything else along the bar.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.title = ""
        statusItem = item

        let menu = NSMenu()
        statusMenu = menu

        let deviceStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        deviceStatusItem.isEnabled = false
        menu.addItem(deviceStatusItem)
        self.deviceStatusItem = deviceStatusItem

        let remapToggleItem = NSMenuItem(title: "Remapping Enabled", action: #selector(toggleRemapping), keyEquivalent: "")
        remapToggleItem.target = self
        menu.addItem(remapToggleItem)
        self.remapToggleItem = remapToggleItem

        let resetItem = NSMenuItem(title: "Reset to Defaults", action: #selector(resetToDefaults), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let permissionsItem = NSMenuItem(title: "", action: #selector(requestAccessibilityPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        self.permissionsItem = permissionsItem

        let handyItem = NSMenuItem(title: "", action: #selector(refreshHandyStatus), keyEquivalent: "")
        handyItem.target = self
        menu.addItem(handyItem)
        self.handyItem = handyItem

        let volumePreviewItem = NSMenuItem(title: "Show Volume HUD", action: #selector(showVolumeHUDPreview), keyEquivalent: "")
        volumePreviewItem.target = self
        menu.addItem(volumePreviewItem)
        self.volumePreviewItem = volumePreviewItem

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let accessibilitySettingsItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilitySettingsItem.target = self
        menu.addItem(accessibilitySettingsItem)
        self.accessibilitySettingsItem = accessibilitySettingsItem

        let quitItem = NSMenuItem(title: "Quit Better Options", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
    }

    /// The thumb button is only taken off the mouse while it has a job here;
    /// otherwise it keeps typing Cmd+Tab as it was built to. Dictation counts
    /// as a job only while Handy is open, the same rule the side button uses.
    private func syncThumbButton() {
        let action = self.action(for: .thumbButton)
        thumbButton.isWanted = remappingEnabled
            && action.isSupported
            && (!action.isPushToTalk || handy.isReady)
    }

    /// Gives the thumb button back to the mouse before the app goes away, or it
    /// would do nothing at all until the mouse reconnects.
    func handBackThumbButton() {
        thumbButton.stop()
    }

    private func updateMenu() {
        syncThumbButton()
        let accessibilityGranted = eventTapController.hasAccessibilityPermission
        let inputMonitoringGranted = deviceMonitor.hasInputMonitoring
        let tapReady = eventTapController.isTapInstalled

        deviceStatusItem?.title = deviceMonitor.activeDeviceDisplayName.map { "Devices: \($0)" } ?? "No devices detected"
        deviceStatusItem?.toolTip = deviceMonitor.hasMatchedDevice ? "Device connected" : "No matched device detected"

        // The line says what picking it will do, which is how 0.2 read.
        remapToggleItem?.title = remappingEnabled ? "Disable Remapping" : "Enable Remapping"
        remapToggleItem?.state = remappingEnabled ? .on : .off
        remapToggleItem?.isEnabled = accessibilityGranted && tapReady

        // Both permissions matter and they are granted in different places:
        // without Accessibility nothing can be remapped, without Input
        // Monitoring the mouse and keyboard are invisible and every control
        // silently does nothing. One line names whichever is still missing.
        var missingPermissions: [String] = []
        if !accessibilityGranted {
            missingPermissions.append("Accessibility")
        }
        if !inputMonitoringGranted {
            missingPermissions.append("Input Monitoring")
        }

        if missingPermissions.isEmpty {
            permissionsItem?.title = "Accessibility granted"
            permissionsItem?.isEnabled = false
            accessibilitySettingsItem?.isHidden = true
        } else if accessibilityGranted {
            permissionsItem?.title = "Grant: " + missingPermissions.joined(separator: ", ")
            permissionsItem?.isEnabled = true
            accessibilitySettingsItem?.isHidden = true
        } else {
            permissionsItem?.title = missingPermissions.count > 1
                ? "Grant: " + missingPermissions.joined(separator: ", ")
                : "Accessibility permission required"
            permissionsItem?.isEnabled = true
            accessibilitySettingsItem?.isHidden = false
        }

        handyItem?.title = handyMenuTitle()
    }

    /// One line saying whether the side button can dictate right now, and if
    /// not, what is in the way.
    private func handyMenuTitle() -> String {
        handy.isRunning ? "Handy: ready" : "Handy: not running"
    }

    /// Keeps the list the settings window offers in step with what is plugged
    /// in right now — the mouse, the keyboard, or both.
    private func syncDeviceRegistry() {
        let connected = deviceMonitor.connectedKnownDevices
        let connectedIDs = Set(connected.map(\.id))

        for device in deviceRegistry.connected where !connectedIDs.contains(device.id) {
            deviceRegistry.remove(id: device.id)
        }

        for device in connected {
            deviceRegistry.register(name: device.model, type: device.type)
        }
    }

    @objc
    private func openSettings() {
        syncDeviceRegistry()
        settingsWindowController.show()
    }

    @objc
    private func toggleRemapping() {
        remappingEnabled.toggle()
    }

    @objc
    private func resetToDefaults() {
        settingsStore.resetToDefaults(deviceID: deviceRegistry.activeDevice?.id)
        updateMenu()
    }

    /// Picking the permissions line asks for whichever one is still missing.
    @objc
    private func requestAccessibilityPermissions() {
        guard eventTapController.hasAccessibilityPermission else {
            evaluateAccessibilityPermissions(promptIfNeeded: true)
            return
        }

        openInputMonitoringSettings()
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

        // Without Accessibility nothing can be posted, so a hold has no way to
        // end on its own. Try to let go anyway before the door closes.
        releaseHeldControls()

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
    private func refreshHandyStatus() {
        handy.refreshConfiguration()
        updateMenu()
    }

    @objc
    private func showVolumeHUDPreview() {
        volumeHUDController.show(volume: mediaKeySender.currentVolume() ?? 0.5)
    }

    @objc
    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
