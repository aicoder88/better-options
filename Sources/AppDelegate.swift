import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    /// Quitting mid-hold would otherwise leave dictation running with nothing
    /// left on this Mac able to stop it.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.releaseHeldControls()
        coordinator?.handBackThumbButton()
    }
}
