// Builds the real settings window against a throwaway settings file and checks
// that picking a different action writes that file straight away, and that a
// fresh start reads the change back.
//
// Run it with: ./scripts/check-settings-window.sh
//
// It never touches the real settings file, and the window is never put on
// screen: the app runs with no Dock icon and nothing is brought to the front.

import AppKit
import SwiftUI

var failures: [String] = []

func expect(_ passed: Bool, _ what: String) {
    if passed {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        failures.append(what)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ wanted: T, _ what: String) {
    if actual == wanted {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what) — got \(actual), wanted \(wanted)")
        failures.append(what)
    }
}

/// The file the 0.2 build left behind, copied so the real one is never written.
let recoveredSettingsJSON = """
{
  "bindings" : [
    {
      "action" : "volumeUp",
      "deviceID" : "mx-master-3",
      "trigger" : {
        "thumbWheelLeft" : {

        }
      }
    },
    {
      "action" : "volumeDown",
      "deviceID" : "mx-master-3",
      "trigger" : {
        "thumbWheelRight" : {

        }
      }
    },
    {
      "action" : "wisprPTT",
      "deviceID" : "mx-master-3",
      "trigger" : {
        "sideButton" : {

        }
      }
    }
  ],
  "enabled" : true,
  "version" : 1
}
"""

@MainActor
func runChecks() throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("better-options-window-check-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let settingsFile = scratch.appendingPathComponent("settings.json")
    try Data(recoveredSettingsJSON.utf8).write(to: settingsFile)

    let registry = DeviceRegistry()
    registry.register(name: "MX Master 3")

    let store = SettingsStore(fileURL: settingsFile)
    expect(store.load(), "the window opens on the saved file")

    let controller = SettingsWindowController(store: store, deviceRegistry: registry)
    let window = controller.window

    print("The window itself")
    expect(window != nil, "there is a window")
    expect(window?.contentView is NSHostingView<SettingsView>, "it is holding the settings view")
    window?.contentView?.layoutSubtreeIfNeeded()
    let size = window?.contentView?.fittingSize ?? .zero
    expect(size.width > 100 && size.height > 100, "the view lays out at \(Int(size.width))x\(Int(size.height))")

    print("What it offers")
    let viewModel = SettingsViewModel(store: store, deviceRegistry: registry)
    expectEqual(viewModel.selectedDeviceID, "mx-master-3", "it opens on the connected mouse")
    expectEqual(viewModel.devices.count, 2, "the mouse and the keyboard are both listed")
    expectEqual(viewModel.devices.first?.isConnected ?? false, true, "shown as connected")
    expectEqual(Trigger.selectable.map(\.displayName).joined(separator: ", "),
                "Thumb Wheel Left, Thumb Wheel Right, Side Button, Thumb Button",
                "all four controls are offered")
    expectEqual(viewModel.choices(for: .thumbWheelLeft).count, Action.selectable.count, "every action is offered")
    expect(viewModel.choices(for: .thumbWheelLeft).contains(.handyPTT), "Handy is one of them")
    expect(viewModel.choices(for: .sideButton).contains(Action(rawValue: "wisprPTT")),
           "an action name from an older build stays on the list instead of vanishing")

    print("Changing a binding")
    viewModel.setAction(.playPause, for: .thumbWheelLeft)
    expectEqual(viewModel.actionsByTrigger[.thumbWheelLeft] ?? .passThrough, .playPause, "the window shows the new choice")

    let afterChange = SettingsStore(fileURL: settingsFile)
    expect(afterChange.load(), "the file still loads after the change")
    expectEqual(afterChange.action(for: .thumbWheelLeft, deviceID: "mx-master-3"), .playPause,
                "the change is in the file, with no Save button pressed")
    expectEqual(afterChange.action(for: .sideButton, deviceID: "mx-master-3").rawValue, "wisprPTT",
                "the other controls were left alone")

    print("Starting up again")
    let restarted = SettingsStore(fileURL: settingsFile)
    expect(restarted.load(), "a fresh start reads the file")
    let restartedViewModel = SettingsViewModel(store: restarted, deviceRegistry: registry)
    expectEqual(restartedViewModel.actionsByTrigger[.thumbWheelLeft] ?? .passThrough, .playPause,
                "the change survived the restart")

    print("Reset to Defaults")
    restartedViewModel.resetToDefaults()
    expectEqual(restartedViewModel.actionsByTrigger[.thumbWheelLeft] ?? .passThrough, .volumeUp, "wheel left is volume again")
    expectEqual(restartedViewModel.actionsByTrigger[.thumbWheelRight] ?? .passThrough, .volumeDown, "wheel right is volume again")
    expectEqual(restartedViewModel.actionsByTrigger[.sideButton] ?? .passThrough, .handyPTT, "the side button is Handy again")

    let afterReset = SettingsStore(fileURL: settingsFile)
    expect(afterReset.load(), "the file loads after the reset")
    expectEqual(afterReset.action(for: .sideButton, deviceID: "mx-master-3"), .handyPTT, "the reset was written too")

    print("The thumb wheel rows")
    expect(restartedViewModel.showsWheelOptions, "a mouse gets the wheel rows")
    expectEqual(restartedViewModel.wheelSensitivity, 1, "the wheel starts on every tick")
    expectEqual(restartedViewModel.wheelSensitivityLabel(1), "Every tick", "which reads plainly")
    expectEqual(restartedViewModel.wheelSensitivityLabel(3), "Every 3 ticks", "and so does a slower one")
    expect(!restartedViewModel.reverseWheel, "and is not reversed")

    restartedViewModel.wheelSensitivitySelection.wrappedValue = 3
    restartedViewModel.reverseWheelSelection.wrappedValue = true
    expectEqual(restartedViewModel.wheelSensitivity, 3, "picking three ticks shows three ticks")
    expect(restartedViewModel.reverseWheel, "and the switch stays where it was put")

    let afterWheel = SettingsStore(fileURL: settingsFile)
    expect(afterWheel.load(), "the file loads after both were changed")
    expectEqual(afterWheel.wheelSensitivity, 3, "three ticks was written, with no Save button pressed")
    expect(afterWheel.reverseWheel, "and so was reversed")

    restartedViewModel.wheelSensitivitySelection.wrappedValue = 1
    restartedViewModel.reverseWheelSelection.wrappedValue = false

    print("A mouse that is not plugged in")
    let unpluggedStore = SettingsStore(fileURL: settingsFile)
    expect(unpluggedStore.load(), "loads")
    let unpluggedViewModel = SettingsViewModel(store: unpluggedStore, deviceRegistry: DeviceRegistry())
    expectEqual(unpluggedViewModel.devices.count, 2, "the mouse and the keyboard are both listed")
    expectEqual(unpluggedViewModel.devices.first?.menuLabel ?? "", "MX Master 3 (not connected)", "and says so")
    expectEqual(unpluggedViewModel.selectedDeviceID, "mx-master-3", "its bindings can still be edited")

    print("The keyboard")
    let keyboardViewModel = SettingsViewModel(store: unpluggedStore, deviceRegistry: DeviceRegistry())
    keyboardViewModel.deviceSelection.wrappedValue = "mx-keys-s"
    expectEqual(keyboardViewModel.triggers.count, ConsumerKey.selectable.count, "shows the function row")
    expectEqual(
        keyboardViewModel.triggers.first?.displayName ?? "",
        "Brightness Down Key",
        "and names the keys"
    )
    expectEqual(
        keyboardViewModel.actionsByTrigger[.consumerKey(ConsumerKey.volumeUp)] ?? .volumeUp,
        .passThrough,
        "an untouched key is left alone"
    )

    print("Pointing a key somewhere else")
    keyboardViewModel.setAction(.playPause, for: .consumerKey(ConsumerKey.mute))
    let reloadedStore = SettingsStore(fileURL: settingsFile)
    expect(reloadedStore.load(), "the change was written")
    expectEqual(
        reloadedStore.action(for: .consumerKey(ConsumerKey.mute), deviceID: "mx-keys-s"),
        .playPause,
        "and comes back after a restart"
    )
    expectEqual(
        reloadedStore.action(for: .consumerKey(ConsumerKey.volumeUp), deviceID: "mx-keys-s"),
        .passThrough,
        "without touching the key next to it"
    )
    expectEqual(
        reloadedStore.action(for: .thumbWheelLeft, deviceID: "mx-master-3"),
        .volumeUp,
        "or anything on the mouse"
    )
}

try MainActor.assumeIsolated { try runChecks() }

if failures.isEmpty {
    print("\nAll checks passed.")
} else {
    print("\n\(failures.count) check(s) failed:")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
