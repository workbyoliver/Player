import AppKit

@main
enum PlayerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let nowPlaying = NowPlayingService()
    private let volume = VolumeService()
    private let appVolumes = AppVolumes()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to the helper after it died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        statusItem = StatusItemController(nowPlaying: nowPlaying, volume: volume, appVolumes: appVolumes)
        nowPlaying.start()
        followSources()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appVolumes.releaseAll()
        nowPlaying.stop()
    }

    /// Per-app volume taps follow apps as they start, quit and relaunch.
    private func followSources() {
        withObservationTracking {
            appVolumes.update(sources: nowPlaying.sources)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.followSources() }
        }
    }
}
