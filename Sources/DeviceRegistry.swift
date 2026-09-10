import Foundation

/// Whether a device is pointed at with the hand or typed on.
///
/// It decides which controls the settings window offers for it: a mouse has a
/// wheel and a side button, a keyboard has a function row.
enum DeviceType: String, Hashable, Codable {
    case mouse
    case keyboard

    var displayName: String {
        switch self {
        case .mouse: return "Mouse"
        case .keyboard: return "Keyboard"
        }
    }
}

/// A device this app knows how to remap, and the name the Mac reports for it.
///
/// The Mac's own name is longer and cased differently than the model — the
/// mouse says `MX Master 3 Mac`, the keyboard says `MX KEYS S MAC` — so
/// matching is on a prefix, ignoring case. Bindings are saved against the
/// model, which is what the file already on disk uses.
struct KnownDevice: Hashable {
    let model: String
    let type: DeviceType

    static let all: [KnownDevice] = [
        KnownDevice(model: "MX Master 3", type: .mouse),
        KnownDevice(model: "MX Keys S", type: .keyboard),
    ]

    var id: String {
        Device.identifier(for: model)
    }

    /// The known device a reported product name belongs to, or nothing when
    /// this app does not handle it.
    static func matching(productName: String) -> KnownDevice? {
        all.first { device in
            productName.lowercased().hasPrefix(device.model.lowercased())
        }
    }

    /// The controls this device offers, in the order the settings window shows
    /// them.
    var triggers: [Trigger] {
        switch type {
        case .mouse: return Trigger.selectable
        case .keyboard: return ConsumerKey.selectable.map(Trigger.consumerKey)
        }
    }
}

/// A device the Mac can see right now.
struct Device: Hashable, Identifiable {
    /// The name used in the settings file, e.g. `mx-master-3`.
    let id: String
    /// The name a person reads, e.g. `MX Master 3`.
    let name: String
    /// Whether it is a mouse or a keyboard.
    let type: DeviceType

    init(name: String, type: DeviceType = .mouse) {
        self.id = Device.identifier(for: name)
        self.name = name
        self.type = type
    }

    /// Turns a product name into the short name the settings file uses:
    /// lower case, spaces and punctuation become single dashes.
    ///
    /// `MX Master 3` becomes `mx-master-3`, which is what the file already on
    /// disk was written with, so old bindings keep matching.
    static func identifier(for name: String) -> String {
        let dashed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }

        return String(dashed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}

/// Keeps the list of connected devices, so the menu and the settings window
/// can show which ones are in use.
final class DeviceRegistry {
    private var devices: [String: Device] = [:]
    private var order: [String] = []

    /// Fires whenever a device connects or disconnects.
    var onChange: (() -> Void)?

    /// Connected devices, in the order they were seen.
    var connected: [Device] {
        order.compactMap { devices[$0] }
    }

    /// The mouse whose bindings apply — the first one connected.
    ///
    /// Nothing when no mouse is connected. It used to answer with whatever was
    /// connected, so with only the keyboard plugged in the keyboard was handed
    /// back as "the mouse" and the mouse's controls were looked up under the
    /// keyboard's name.
    var activeDevice: Device? {
        connected.first { $0.type == .mouse }
    }

    /// The keyboard whose bindings apply — the first one connected.
    var activeKeyboard: Device? {
        connected.first { $0.type == .keyboard }
    }

    /// Names for the menu, or nothing when nothing is connected.
    var displayName: String? {
        let names = connected.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    @discardableResult
    func register(name: String, type: DeviceType = .mouse) -> Device {
        let device = Device(name: name, type: type)

        if devices.updateValue(device, forKey: device.id) == nil {
            order.append(device.id)
            onChange?()
        }

        return device
    }

    func remove(id: String) {
        guard devices.removeValue(forKey: id) != nil else {
            return
        }

        order.removeAll { $0 == id }
        onChange?()
    }
}
