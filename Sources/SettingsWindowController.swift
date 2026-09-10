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
    private var refreshTimer: Timer?

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
        watchForDeviceChanges()
    }

    /// Keeps the open window in step with what is plugged in.
    ///
    /// A mouse connected or unplugged while the window sits open used to leave
    /// it showing a list that was already wrong, until it was closed and opened
    /// again. It stops on its own once the window is out of sight.
    private func watchForDeviceChanges() {
        guard refreshTimer == nil else {
            return
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }

                guard self.window?.isVisible == true else {
                    timer.invalidate()
                    self.refreshTimer = nil
                    return
                }

                self.viewModel.refresh()
            }
        }
    }
}
