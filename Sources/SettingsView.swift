import SwiftUI

/// One mouse the settings window can edit.
///
/// A mouse that is unplugged still shows up when the settings file holds
/// bindings for it, so unplugging the mouse never hides the bindings you saved
/// for it.
struct DeviceChoice: Hashable, Identifiable {
    let id: String
    let name: String
    let type: DeviceType
    let isConnected: Bool

    var menuLabel: String {
        isConnected ? name : name + " (not connected)"
    }
}

/// What the settings window is showing: which mouse is being edited, and what
/// each of its controls does.
///
/// Every change goes straight through `SettingsStore`, which writes the file.
/// There is no OK or Apply button and nothing waits in memory to be saved, so
/// quitting right after a change keeps the change.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var devices: [DeviceChoice] = []
    @Published private(set) var selectedDeviceID: String = ""
    @Published private(set) var actionsByTrigger: [Trigger: Action] = [:]

    /// The controls the selected device has: a wheel and a side button on the
    /// mouse, the function row on the keyboard.
    @Published private(set) var triggers: [Trigger] = Trigger.selectable

    /// Whether the selected device has a thumb wheel to set up.
    @Published private(set) var showsWheelOptions = true
    @Published private(set) var wheelSensitivity = Settings.defaultWheelSensitivity
    @Published private(set) var reverseWheel = false

    private let store: SettingsStore
    private let deviceRegistry: DeviceRegistry

    init(store: SettingsStore, deviceRegistry: DeviceRegistry) {
        self.store = store
        self.deviceRegistry = deviceRegistry
        refresh()
    }

    /// Rereads the mouse list and the saved bindings.
    ///
    /// Runs when the window opens and every couple of seconds while it is open,
    /// so a mouse plugged in or unplugged in front of the window shows up
    /// without it being closed and opened again. Nothing is written back unless
    /// it actually changed, so an open picker is never yanked out from under a
    /// hand.
    func refresh() {
        let found = availableDevices()
        if found != devices {
            devices = found
        }

        if !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id ?? store.defaultDeviceID
        }

        reloadActions()
    }

    /// The name of the device being edited, for the reset warning.
    var selectedDeviceName: String {
        devices.first(where: { $0.id == selectedDeviceID })?.name ?? selectedDeviceID
    }

    /// A two-way link between the wheel sensitivity picker and the saved file.
    var wheelSensitivitySelection: Binding<Int> {
        Binding(
            get: { [weak self] in self?.wheelSensitivity ?? Settings.defaultWheelSensitivity },
            set: { [weak self] value in
                self?.store.wheelSensitivity = value
                self?.reloadActions()
            }
        )
    }

    /// A two-way link between the reverse-wheel switch and the saved file.
    var reverseWheelSelection: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.reverseWheel ?? false },
            set: { [weak self] value in
                self?.store.reverseWheel = value
                self?.reloadActions()
            }
        )
    }

    /// How a sensitivity number reads in the picker.
    func wheelSensitivityLabel(_ ticks: Int) -> String {
        ticks == 1 ? "Every tick" : "Every \(ticks) ticks"
    }

    /// A two-way link between the mouse picker and this window.
    var deviceSelection: Binding<String> {
        Binding(
            get: { [weak self] in self?.selectedDeviceID ?? "" },
            set: { [weak self] id in
                guard let self, self.selectedDeviceID != id else {
                    return
                }
                self.selectedDeviceID = id
                self.reloadActions()
            }
        )
    }

    /// A two-way link between one action picker and the saved file.
    func actionSelection(for trigger: Trigger) -> Binding<Action> {
        Binding(
            get: { [weak self] in self?.actionsByTrigger[trigger] ?? .passThrough },
            set: { [weak self] action in
                self?.setAction(action, for: trigger)
            }
        )
    }

    /// What one picker offers.
    ///
    /// An action name this build does not know — the live file names a
    /// dictation app it no longer talks to — stays in the list as the current
    /// choice. Otherwise opening the window would silently show something else
    /// and the next click would throw the old setting away.
    func choices(for trigger: Trigger) -> [Action] {
        let current = actionsByTrigger[trigger] ?? .passThrough
        guard !Action.selectable.contains(current) else {
            return Action.selectable
        }

        return Action.selectable + [current]
    }

    func setAction(_ action: Action, for trigger: Trigger) {
        store.setAction(action, for: trigger, deviceID: selectedDeviceID)
        reloadActions()
    }

    /// Puts every control back to what a fresh install would do: the wheel on
    /// volume, the side button on Handy.
    func resetToDefaults() {
        store.resetToDefaults(deviceID: selectedDeviceID)
        refresh()
    }

    private func reloadActions() {
        let found = triggersForSelectedDevice()
        if found != triggers {
            triggers = found
        }

        var actions: [Trigger: Action] = [:]
        for trigger in triggers {
            actions[trigger] = store.action(for: trigger, deviceID: selectedDeviceID)
        }
        if actions != actionsByTrigger {
            actionsByTrigger = actions
        }

        let hasWheel = triggers.contains(.thumbWheelLeft) || triggers.contains(.thumbWheelRight)
        if hasWheel != showsWheelOptions {
            showsWheelOptions = hasWheel
        }
        if store.wheelSensitivity != wheelSensitivity {
            wheelSensitivity = store.wheelSensitivity
        }
        if store.reverseWheel != reverseWheel {
            reverseWheel = store.reverseWheel
        }
    }

    /// A device this app has never heard of can still hold bindings in the
    /// file, so fall back to the mouse controls rather than showing nothing.
    private func triggersForSelectedDevice() -> [Trigger] {
        if let known = KnownDevice.all.first(where: { $0.id == selectedDeviceID }) {
            return known.triggers
        }

        let type = devices.first(where: { $0.id == selectedDeviceID })?.type ?? .mouse
        return KnownDevice.all.first(where: { $0.type == type })?.triggers ?? Trigger.selectable
    }

    /// Connected devices first, then anything else the settings file mentions.
    private func availableDevices() -> [DeviceChoice] {
        var choices = deviceRegistry.connected.map {
            DeviceChoice(id: $0.id, name: $0.name, type: $0.type, isConnected: true)
        }

        var seen = Set(choices.map(\.id))

        // A known device that is unplugged still gets a row, so its keys can be
        // set up before it is next connected.
        for known in KnownDevice.all where !seen.contains(known.id) {
            seen.insert(known.id)
            choices.append(DeviceChoice(id: known.id, name: known.model, type: known.type, isConnected: false))
        }

        for binding in store.settings.bindings where !seen.contains(binding.deviceID) {
            seen.insert(binding.deviceID)
            choices.append(
                DeviceChoice(id: binding.deviceID, name: binding.deviceID, type: .mouse, isConnected: false)
            )
        }

        return choices
    }
}

/// The settings window: one row per control on the mouse, each pointing at
/// whatever it should do.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isConfirmingReset = false

    /// Says which device is about to change, because only that one does now.
    private var resetWarning: String {
        "Only \(viewModel.selectedDeviceName) changes. Every other device keeps the bindings you gave it."
    }

    var body: some View {
        Form {
            Section {
                Picker("Device", selection: viewModel.deviceSelection) {
                    ForEach(viewModel.devices) { device in
                        Text(device.menuLabel).tag(device.id)
                    }
                }
                .disabled(viewModel.devices.count < 2)
            }

            if viewModel.showsWheelOptions {
                Section("Thumb wheel") {
                    Picker("Wheel sensitivity", selection: viewModel.wheelSensitivitySelection) {
                        ForEach(Settings.wheelSensitivityChoices, id: \.self) { ticks in
                            Text(viewModel.wheelSensitivityLabel(ticks)).tag(ticks)
                        }
                    }

                    Toggle("Reverse wheel", isOn: viewModel.reverseWheelSelection)
                }
            }

            Section("What each control does") {
                ForEach(viewModel.triggers, id: \.self) { trigger in
                    Picker(trigger.displayName, selection: viewModel.actionSelection(for: trigger)) {
                        ForEach(viewModel.choices(for: trigger), id: \.self) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Changes are saved as you make them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset to Defaults") {
                        isConfirmingReset = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            "Put every control back to its default?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset to Defaults", role: .destructive) {
                viewModel.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetWarning)
        }
    }
}
