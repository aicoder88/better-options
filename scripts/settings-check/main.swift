// Checks the settings file can be read and written back without a single byte
// changing, so the file the 0.2 build left behind keeps working.
//
// Run it with: ./scripts/check-settings.sh
//
// It never writes to the real settings file. Every write goes to a throwaway
// copy in a temporary folder.

import Foundation

/// The exact text the 0.2 build left in
/// `~/Library/Application Support/BetterOptions/settings.json` on 2026-03-25.
/// Kept here so the check still runs on a Mac that does not have that file.
/// `wisprPTT` names a dictation app this build no longer talks to, and it has to
/// survive a read and write untouched.
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

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("better-options-settings-check-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

var copyCount = 0
func workingCopy(of data: Data?) throws -> URL {
    copyCount += 1
    let url = scratch.appendingPathComponent("copy-\(copyCount)", isDirectory: true)
        .appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data {
        try data.write(to: url)
    }
    return url
}

/// Reads a settings file, writes it straight back, and expects the same bytes.
func checkRoundTripKeepsEveryByte(of original: Data, _ what: String) throws {
    let copy = try workingCopy(of: original)
    let store = SettingsStore(fileURL: copy)
    expect(store.load(), "\(what): the file loads")
    try store.save()

    let rewritten = try Data(contentsOf: copy)
    if rewritten == original {
        print("  ok   \(what): saving changed nothing (\(original.count) bytes)")
    } else {
        print("  FAIL \(what): saving changed the file")
        print("--- was ---")
        print(String(data: original, encoding: .utf8) ?? "<not text>")
        print("--- now ---")
        print(String(data: rewritten, encoding: .utf8) ?? "<not text>")
        failures.append(what)
    }
}

print("Settings round trip")
try checkRoundTripKeepsEveryByte(of: Data(recoveredSettingsJSON.utf8), "recovered 0.2 file")

let live = SettingsStore.defaultFileURL
if FileManager.default.fileExists(atPath: live.path) {
    let before = try Data(contentsOf: live)
    try checkRoundTripKeepsEveryByte(of: before, "the real file on this Mac")
    expect(try Data(contentsOf: live) == before, "the real file was left alone")
} else {
    print("  skip no settings file at \(live.path)")
}

print("Reading the saved bindings")
do {
    let copy = try workingCopy(of: Data(recoveredSettingsJSON.utf8))
    let store = SettingsStore(fileURL: copy)
    expect(store.load(), "loads")
    expect(store.isEnabled, "remapping is on")
    expectEqual(store.settings.version, 1, "version is 1")
    expectEqual(store.settings.bindings.count, 3, "three bindings")
    expectEqual(store.action(for: .thumbWheelLeft, deviceID: "mx-master-3"), .volumeUp, "wheel left turns volume up")
    expectEqual(store.action(for: .thumbWheelRight, deviceID: "mx-master-3"), .volumeDown, "wheel right turns volume down")
    expectEqual(store.action(for: .sideButton, deviceID: "mx-master-3").rawValue, "wisprPTT", "the side button keeps its old name")
    expectEqual(store.action(for: .sideButton, deviceID: "another-mouse"), .passThrough, "another mouse is left alone")
}

// Read straight out of the 0.2 app. If any of these spellings drift, a setup
// saved by 0.2 quietly stops working on the key it was saved for.
print("The names 0.2 wrote into the file")
do {
    expectEqual(Action.passThrough.rawValue, "passthrough", "Default (Pass Through)")
    expectEqual(Action.volumeUp.rawValue, "volumeUp", "Volume Up")
    expectEqual(Action.volumeDown.rawValue, "volumeDown", "Volume Down")
    expectEqual(Action.toggleMute.rawValue, "volumeMute", "Toggle Mute")
    expectEqual(Action.brightnessUp.rawValue, "brightnessUp", "Brightness Up")
    expectEqual(Action.brightnessDown.rawValue, "brightnessDown", "Brightness Down")
    expectEqual(Action.playPause.rawValue, "mediaPlayPause", "Play / Pause")
    expectEqual(Action.previousTrack.rawValue, "mediaPrevious", "Previous Track")
    expectEqual(Action.nextTrack.rawValue, "mediaNext", "Next Track")

    expect(Action(rawValue: "wisprPTT").isPushToTalk, "the old dictation name still starts dictation")
    expect(Action.gvoicePTT.isPushToTalk, "and so does the current one")
    expect(!Action.volumeUp.isPushToTalk, "turning the volume up does not")
    expect(!Action(rawValue: "somethingNewer").isPushToTalk, "nor does a name from a future build")

    // A whole setup saved by 0.2, every action it had, loading here.
    let everyAction = """
    {"bindings":[\
    {"action":"volumeMute","deviceID":"mx-keys-s","trigger":{"consumerKey":{"usage":226}}},\
    {"action":"mediaNext","deviceID":"mx-keys-s","trigger":{"consumerKey":{"usage":181}}},\
    {"action":"mediaPlayPause","deviceID":"mx-master-3","trigger":{"sideButton":{}}},\
    {"action":"passthrough","deviceID":"mx-master-3","trigger":{"thumbWheelLeft":{}}}\
    ],"enabled":true,"version":1}
    """
    let copy = try workingCopy(of: Data(everyAction.utf8))
    let store = SettingsStore(fileURL: copy)
    expect(store.load(), "a full 0.2 setup loads")
    expectEqual(store.action(for: .consumerKey(0xE2), deviceID: "mx-keys-s"), .toggleMute, "its mute key still mutes")
    expectEqual(store.action(for: .consumerKey(0xB5), deviceID: "mx-keys-s"), .nextTrack, "its next-track key still skips")
    expectEqual(store.action(for: .sideButton, deviceID: "mx-master-3"), .playPause, "its side button still plays")
    expectEqual(store.action(for: .thumbWheelLeft, deviceID: "mx-master-3"), .passThrough, "its wheel is still left alone")
}

print("Changing a binding")
do {
    let copy = try workingCopy(of: Data(recoveredSettingsJSON.utf8))
    let store = SettingsStore(fileURL: copy)
    expect(store.load(), "loads")
    store.setAction(.toggleMute, for: .sideButton, deviceID: "mx-master-3")

    let reopened = SettingsStore(fileURL: copy)
    expect(reopened.load(), "loads again after the change")
    expectEqual(reopened.action(for: .sideButton, deviceID: "mx-master-3"), .toggleMute, "the change was saved")
    expectEqual(reopened.settings.bindings.count, 3, "still three bindings")

    store.isEnabled = false
    let reopenedAgain = SettingsStore(fileURL: copy)
    expect(reopenedAgain.load(), "loads after switching remapping off")
    expect(!reopenedAgain.isEnabled, "remapping stays off")
}

print("No settings file yet")
do {
    let missing = try workingCopy(of: nil)
    let store = SettingsStore(fileURL: missing)
    expect(!store.load(), "reports there was nothing to load")
    expect(!FileManager.default.fileExists(atPath: missing.path), "writes nothing on its own")
    expectEqual(store.action(for: .thumbWheelLeft, deviceID: "mx-master-3"), .volumeUp, "falls back to wheel left = volume up")
    expectEqual(store.action(for: .sideButton, deviceID: "mx-master-3"), .gvoicePTT, "falls back to side button = GVoice")
}

print("Mice")
do {
    expectEqual(Device.identifier(for: "MX Master 3"), "mx-master-3", "the mouse name matches the one in the saved file")
    expectEqual(Device.identifier(for: "MX Master 3S"), "mx-master-3s", "a newer mouse gets its own name")

    let registry = DeviceRegistry()
    var changes = 0
    registry.onChange = { changes += 1 }

    expect(registry.displayName == nil, "no mouse connected yet")
    let device = registry.register(name: "MX Master 3")
    expectEqual(device.id, "mx-master-3", "connecting gives the saved name")
    expectEqual(registry.displayName ?? "", "MX Master 3", "the menu name reads plainly")
    expectEqual(registry.activeDevice?.id ?? "", "mx-master-3", "it is the active mouse")

    registry.register(name: "MX Master 3")
    expectEqual(registry.connected.count, 1, "the same mouse is not counted twice")
    expectEqual(changes, 1, "and is not announced twice")

    registry.register(name: "MX Anywhere 3")
    expectEqual(registry.displayName ?? "", "MX Master 3, MX Anywhere 3", "two mice list in the order they connected")

    registry.remove(id: "mx-master-3")
    expectEqual(registry.activeDevice?.id ?? "", "mx-anywhere-3", "unplugging one leaves the other")
}

if failures.isEmpty {
    print("\nAll checks passed.")
} else {
    print("\n\(failures.count) check(s) failed:")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
