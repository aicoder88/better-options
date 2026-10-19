import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator?.start()
        quitCleanlyOnTerminationSignal()
    }

    /// Quitting mid-hold would otherwise leave dictation running with nothing
    /// left on this Mac able to stop it.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.releaseHeldControls()
        coordinator?.handBackThumbButton()
    }

    /// launchctl and kill stop the app with SIGTERM, which skips
    /// applicationWillTerminate and would leave the thumb button taken over
    /// with nobody listening. Turn it into an ordinary quit instead.
    private func quitCleanlyOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }
}
