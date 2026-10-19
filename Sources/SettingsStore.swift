import Foundation

/// What a physical control on the mouse or keyboard is called in the saved
/// settings file.
///
/// Stored as a one-key object (`{"sideButton": {}}`) because that is the shape
/// the 0.2 build wrote, and the file on disk has to keep loading unchanged.
/// Unknown names survive a load/save round trip instead of being dropped, so a
/// file written by a newer build never loses bindings when an older one saves.
///
/// A keyboard key needs one extra thing a mouse control does not: *which* key.
/// Every key on the function row reports the same control name, so the key's
/// HID usage number rides along inside the same object
/// (`{"consumerKey": {"usage": 233}}`). Mouse controls carry no usage and keep
/// writing the empty object they always did.
struct Trigger: RawRepresentable, Hashable, Codable {
    let rawValue: String
    /// Which key on the keyboard, for controls where the name alone is not
    /// enough to tell them apart. Always nil for the mouse.
    let usage: UInt32?

    init(rawValue: String) {
        self.init(rawValue: rawValue, usage: nil)
    }

    init(rawValue: String, usage: UInt32?) {
        self.rawValue = rawValue
        self.usage = usage
    }

    /// Written out by hand because a `RawRepresentable` gets a free `==` that
    /// only ever looks at `rawValue` — which would make every key on the
    /// function row equal to every other one, and pointing one key somewhere
    /// new would move them all.
    static func == (lhs: Trigger, rhs: Trigger) -> Bool {
        lhs.rawValue == rhs.rawValue && lhs.usage == rhs.usage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
        hasher.combine(usage)
    }

    static let thumbWheelLeft = Trigger(rawValue: "thumbWheelLeft")
    static let thumbWheelRight = Trigger(rawValue: "thumbWheelRight")
    static let sideButton = Trigger(rawValue: "sideButton")
    /// The gesture button under the thumb. It only reports holds while
    /// `ThumbButtonDiverter` has taken it over.
    static let thumbButton = Trigger(rawValue: "thumbButton")

    /// One key on the keyboard's function row, named by its HID usage number.
    static func consumerKey(_ usage: UInt32) -> Trigger {
        Trigger(rawValue: "consumerKey", usage: usage)
    }

    /// The mouse controls the settings window offers, in the order it shows
    /// them. Keyboard keys come from `ConsumerKey.selectable` instead, because
    /// they vary by keyboard.
    static let selectable: [Trigger] = [.thumbWheelLeft, .thumbWheelRight, .sideButton, .thumbButton]

    var displayName: String {
        switch rawValue {
        case "thumbWheelLeft": return "Thumb Wheel Left"
        case "thumbWheelRight": return "Thumb Wheel Right"
        case "sideButton": return "Side Button"
        case "thumbButton": return "Thumb Button"
        case "consumerKey": return usage.map(ConsumerKey.displayName(for:)) ?? "Keyboard Key"
        default: return rawValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A trigger must name exactly one control."
                )
            )
        }

        let details = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
        let usage = try details.decodeIfPresent(UInt32.self, forKey: DynamicCodingKey(stringValue: "usage"))
        self.init(rawValue: key.stringValue, usage: usage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        let key = DynamicCodingKey(stringValue: rawValue)

        // A control with no usage writes the empty object 0.2 wrote, so a file
        // that predates keyboard support comes back byte for byte the same.
        guard let usage else {
            try container.encode([String: String](), forKey: key)
            return
        }

        try container.encode(["usage": usage], forKey: key)
    }
}

/// The keys on a keyboard's function row that can be pointed at an action.
///
/// These are the standard HID consumer-control numbers the keyboard itself
/// sends; the keyboard is the one naming them, not this app.
enum ConsumerKey {
    static let volumeUp: UInt32 = 0xE9
    static let volumeDown: UInt32 = 0xEA
    static let mute: UInt32 = 0xE2
    static let playPause: UInt32 = 0xCD
    static let nextTrack: UInt32 = 0xB5
    static let previousTrack: UInt32 = 0xB6
    static let brightnessUp: UInt32 = 0x6F
    static let brightnessDown: UInt32 = 0x70

    /// The keys the settings window lists, in function-row order.
    static let selectable: [UInt32] = [
        brightnessDown,
        brightnessUp,
        previousTrack,
        playPause,
        nextTrack,
        mute,
        volumeDown,
        volumeUp,
    ]

    /// The same key as macOS numbers it in its own media-key events.
    ///
    /// The keyboard and macOS count these keys differently, so a press has to
    /// be translated before the two can be matched up and the Mac's own copy
    /// swallowed.
    static func usage(forSystemKeyCode keyCode: Int) -> UInt32? {
        switch keyCode {
        case 0: return volumeUp
        case 1: return volumeDown
        case 2: return brightnessUp
        case 3: return brightnessDown
        case 7: return mute
        case 16: return playPause
        case 17: return nextTrack
        case 18: return previousTrack
        default: return nil
        }
    }

    /// The name printed on the key. An unlisted number still gets a readable
    /// name rather than disappearing from the window.
    static func displayName(for usage: UInt32) -> String {
        switch usage {
        case volumeUp: return "Volume Up Key"
        case volumeDown: return "Volume Down Key"
        case mute: return "Mute Key"
        case playPause: return "Play / Pause Key"
        case nextTrack: return "Next Track Key"
        case previousTrack: return "Previous Track Key"
        case brightnessUp: return "Brightness Up Key"
        case brightnessDown: return "Brightness Down Key"
        default: return "Key \(usage)"
        }
    }

}

/// What a control does when it is used.
///
/// Stored as a plain string. Names this build does not recognise are carried
/// through untouched, which is what keeps the live file — written by 0.2, and
/// naming a dictation app this build no longer talks to — loading and saving
/// byte for byte the same.
struct Action: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    // These spellings are the ones 0.2 wrote into the file, read back out of
    // the 0.2 app itself. They are not free to rename: a binding saved as
    // `volumeMute` has to still mean Toggle Mute here, or the key it is on
    // goes dead after the upgrade.
    static let passThrough = Action(rawValue: "passthrough")
    static let volumeUp = Action(rawValue: "volumeUp")
    static let volumeDown = Action(rawValue: "volumeDown")
    static let toggleMute = Action(rawValue: "volumeMute")
    static let brightnessUp = Action(rawValue: "brightnessUp")
    static let brightnessDown = Action(rawValue: "brightnessDown")
    static let playPause = Action(rawValue: "mediaPlayPause")
    static let previousTrack = Action(rawValue: "mediaPrevious")
    static let nextTrack = Action(rawValue: "mediaNext")
    static let handyPTT = Action(rawValue: "handyPTT")
    static let previousApp = Action(rawValue: "previousApp")

    /// The choices the settings window offers, in the order it shows them.
    static let selectable: [Action] = [
        .passThrough,
        .volumeUp,
        .volumeDown,
        .toggleMute,
        .brightnessUp,
        .brightnessDown,
        .playPause,
        .previousTrack,
        .nextTrack,
        .handyPTT,
        .previousApp,
    ]

    /// Whether this means hold-to-talk dictation.
    ///
    /// Matches on the ending rather than a fixed list, so names saved for the
    /// dictation apps that came before Handy (GVoice and earlier) still start
    /// dictation.
    var isPushToTalk: Bool {
        rawValue.hasSuffix("PTT")
    }

    /// Whether this build can actually carry the action out.
    ///
    /// A name written by a newer build is kept in the file, but this build has
    /// no idea what it means. Treat it the way Pass Through is treated: leave
    /// the control alone, so the key or button keeps doing what it is printed
    /// with instead of being swallowed and then doing nothing at all.
    var isSupported: Bool {
        if isPushToTalk {
            return true
        }

        return self != .passThrough && Action.selectable.contains(self)
    }

    var displayName: String {
        switch self {
        case .passThrough: return "Default (Pass Through)"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleMute: return "Toggle Mute"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .playPause: return "Play / Pause"
        case .previousTrack: return "Previous Track"
        case .nextTrack: return "Next Track"
        case .handyPTT: return "Handy Push-to-Talk"
        case .previousApp: return "Switch to Last App"
        default: return rawValue
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One control on one mouse, and what it does.
///
/// Not called `Binding`: SwiftUI already owns that name, and the settings window
/// uses it.
struct TriggerBinding: Hashable, Codable {
    var deviceID: String
    var trigger: Trigger
    var action: Action
}

/// Everything the settings file holds.
///
/// The two thumb-wheel preferences are written out only once they are moved off
/// the value every earlier build behaved as. A file saved before they existed
/// therefore still comes back byte for byte the same.
struct Settings: Hashable, Codable {
    static let currentVersion = 1
    /// One step per tick: what the wheel has always done.
    static let defaultWheelSensitivity = 1
    static let wheelSensitivityChoices = [1, 2, 3, 4, 5]

    var bindings: [TriggerBinding]
    var enabled: Bool
    var version: Int
    /// How many wheel ticks it takes to fire the wheel's action once.
    var wheelSensitivity: Int
    /// Swaps which way of the wheel counts as left and which as right.
    var reverseWheel: Bool

    init(
        bindings: [TriggerBinding],
        enabled: Bool,
        version: Int,
        wheelSensitivity: Int = Settings.defaultWheelSensitivity,
        reverseWheel: Bool = false
    ) {
        self.bindings = bindings
        self.enabled = enabled
        self.version = version
        self.wheelSensitivity = Settings.clampedWheelSensitivity(wheelSensitivity)
        self.reverseWheel = reverseWheel
    }

    /// A number outside the range the window offers would make the wheel either
    /// fire nothing at all or fire on a tick that never comes.
    static func clampedWheelSensitivity(_ value: Int) -> Int {
        guard let lowest = wheelSensitivityChoices.first, let highest = wheelSensitivityChoices.last else {
            return defaultWheelSensitivity
        }

        return min(max(value, lowest), highest)
    }

    static func defaults(deviceID: String) -> Settings {
        Settings(
            bindings: defaultBindings(deviceID: deviceID),
            enabled: true,
            version: currentVersion
        )
    }

    /// What one mouse's controls do on a fresh install.
    static func defaultBindings(deviceID: String) -> [TriggerBinding] {
        [
            TriggerBinding(deviceID: deviceID, trigger: .thumbWheelLeft, action: .volumeUp),
            TriggerBinding(deviceID: deviceID, trigger: .thumbWheelRight, action: .volumeDown),
            TriggerBinding(deviceID: deviceID, trigger: .sideButton, action: .previousApp),
            TriggerBinding(deviceID: deviceID, trigger: .thumbButton, action: .handyPTT),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case bindings
        case enabled
        case version
        case wheelSensitivity
        case reverseWheel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try container.decode([TriggerBinding].self, forKey: .bindings)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        version = try container.decode(Int.self, forKey: .version)
        wheelSensitivity = Settings.clampedWheelSensitivity(
            try container.decodeIfPresent(Int.self, forKey: .wheelSensitivity) ?? Settings.defaultWheelSensitivity
        )
        reverseWheel = try container.decodeIfPresent(Bool.self, forKey: .reverseWheel) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bindings, forKey: .bindings)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(version, forKey: .version)

        // Left out while they say what every build before them did, so a file
        // written by an older build is not rewritten just for being opened.
        if wheelSensitivity != Settings.defaultWheelSensitivity {
            try container.encode(wheelSensitivity, forKey: .wheelSensitivity)
        }
        if reverseWheel {
            try container.encode(reverseWheel, forKey: .reverseWheel)
        }
    }
}

/// Reads and writes `~/Library/Application Support/BetterOptions/settings.json`.
///
/// The file that is already on disk is the one that has to keep working, so the
/// text this writes matches it exactly: two-space indent, keys in alphabetical
/// order, no newline at the end.
final class SettingsStore {
    static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("BetterOptions", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }()

    let fileURL: URL
    /// The mouse whose bindings apply when none is connected, so the settings
    /// window still has something to show.
    let defaultDeviceID: String
    /// The same, for the keyboard.
    let defaultKeyboardID: String

    private(set) var settings: Settings

    /// The last copy known to be on disk. A write that fails puts this back, so
    /// the app never behaves one way while the file says another.
    private var lastSavedSettings: Settings

    /// Fires after any change that has been written to disk.
    var onChange: (() -> Void)?

    /// Fires when a change could not be written. A change that vanishes with
    /// nothing said is the whole reason this exists.
    var onSaveFailure: ((String) -> Void)?

    init(
        fileURL: URL = SettingsStore.defaultFileURL,
        defaultDeviceID: String = "mx-master-3",
        defaultKeyboardID: String = "mx-keys-s"
    ) {
        self.fileURL = fileURL
        self.defaultDeviceID = defaultDeviceID
        self.defaultKeyboardID = defaultKeyboardID
        self.settings = Settings.defaults(deviceID: defaultDeviceID)
        self.lastSavedSettings = self.settings
    }

    /// Loads the file if it is there. A missing or unreadable file leaves the
    /// defaults in memory and writes nothing, so a bad read never wipes
    /// somebody's bindings.
    @discardableResult
    func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return false
        }

        settings = loaded
        lastSavedSettings = loaded
        return true
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        lastSavedSettings = settings
    }

    var isEnabled: Bool {
        get { settings.enabled }
        set {
            guard settings.enabled != newValue else {
                return
            }
            settings.enabled = newValue
            persist()
        }
    }

    /// What a control does on a given mouse. A control nobody has bound is left
    /// alone.
    func action(for trigger: Trigger, deviceID: String) -> Action {
        settings.bindings.first(where: { $0.deviceID == deviceID && $0.trigger == trigger })?.action ?? .passThrough
    }

    func setAction(_ action: Action, for trigger: Trigger, deviceID: String) {
        if let index = settings.bindings.firstIndex(where: { $0.deviceID == deviceID && $0.trigger == trigger }) {
            guard settings.bindings[index].action != action else {
                return
            }
            settings.bindings[index].action = action
        } else {
            settings.bindings.append(TriggerBinding(deviceID: deviceID, trigger: trigger, action: action))
        }

        persist()
    }

    /// How many wheel ticks one action takes.
    var wheelSensitivity: Int {
        get { settings.wheelSensitivity }
        set {
            let wanted = Settings.clampedWheelSensitivity(newValue)
            guard settings.wheelSensitivity != wanted else {
                return
            }
            settings.wheelSensitivity = wanted
            persist()
        }
    }

    /// Whether the two ways of the wheel are swapped.
    var reverseWheel: Bool {
        get { settings.reverseWheel }
        set {
            guard settings.reverseWheel != newValue else {
                return
            }
            settings.reverseWheel = newValue
            persist()
        }
    }

    /// Puts one device's controls back to what a fresh install would do, and
    /// leaves every other device's bindings exactly where they were.
    ///
    /// A mouse gets the wheel back on volume, the side button back on
    /// switching apps and the thumb button back on dictation. A keyboard gets
    /// Pass Through: a key nobody has bound is already left alone, so its
    /// bindings are simply dropped.
    func resetToDefaults(deviceID: String? = nil) {
        let id = deviceID ?? defaultDeviceID
        let type = KnownDevice.all.first(where: { $0.id == id })?.type ?? .mouse

        settings.bindings.removeAll { $0.deviceID == id }

        if type == .mouse {
            settings.bindings.append(contentsOf: Settings.defaultBindings(deviceID: id))
        }

        persist()
    }

    private func persist() {
        do {
            try save()
        } catch {
            // A change that cannot be written would otherwise vanish at quit
            // with nothing to show for it.
            NSLog("Better Options could not save settings to %@: %@", fileURL.path, String(describing: error))
            settings = lastSavedSettings
            onSaveFailure?(String(describing: error))
            onChange?()
            return
        }

        onChange?()
    }
}

/// A key whose name is only known at runtime, used for the one-key trigger
/// object.
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
