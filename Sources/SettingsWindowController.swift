import AppKit
import SwiftUI

/// Owns the settings window.
///
/// The app lives in the menu bar with no Dock icon, so opening the window has
/// to bring the app forward by hand — otherwise the window appears behind
/// whatever is on screen and looks like nothing happened.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel

    init(store: SettingsStore, deviceRegistry: DeviceRegistry) {
        let viewModel = SettingsViewModel(store: store, deviceRegistry: deviceRegistry)
        self.viewModel = viewModel

        let contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Better Options"
        window.contentView = contentView
        // Closing the window must not throw it away: the menu opens the same
        // one again.
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not loaded from a nib.")
    }

    /// Shows the window with what is on disk right now, in front of everything
    /// else.
    func show() {
        viewModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
