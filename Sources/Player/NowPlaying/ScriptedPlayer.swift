import Foundation

/// AppleScript control for players that support it (Music, Spotify).
///
/// MediaRemote only delivers commands to the system's active Now Playing app, so this
/// is how Player controls one of these apps when you've selected it but another app
/// is the active player. macOS asks once for permission to control each app.
struct ScriptedPlayer {
    private let appName: String

    init?(bundleIDs: [String]) {
        if bundleIDs.contains("com.apple.Music") {
            appName = "Music"
        } else if bundleIDs.contains("com.spotify.client") {
            appName = "Spotify"
        } else {
            return nil
        }
    }

    func send(_ command: NowPlayingService.Command) {
        switch command {
        case .play: run("play")
        case .pause: run("pause")
        case .toggle: run("playpause")
        case .next: run("next track")
        case .prev: run("previous track")
        }
    }

    func seek(to seconds: TimeInterval) {
        run("set player position to \(seconds)")
    }

    private func run(_ statement: String) {
        AppleScript.run(["tell application \"\(appName)\" to \(statement)"])
    }
}
