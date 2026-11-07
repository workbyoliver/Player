import AppKit

/// What is playing right now, as reported by the system's Now Playing info.
nonisolated struct Track: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// nil when the player doesn't report one (e.g. live streams).
    var duration: TimeInterval?
    /// Playback position at `timestamp`.
    var elapsed: TimeInterval
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool

    var menuBarText: String {
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(title) — \(artist)"
    }

    /// Players only report the position when something changes, so interpolate.
    func elapsed(at date: Date) -> TimeInterval {
        var value = elapsed
        if isPlaying { value += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if let duration { value = min(value, duration) }
        return max(0, value)
    }

    /// The same track with its position pinned to `date`, so state changes don't make it jump.
    func settled(at date: Date) -> Track {
        var copy = self
        copy.elapsed = elapsed(at: date)
        copy.timestamp = date
        return copy
    }
}

/// An app with something in Now Playing (several can at once).
struct PlayingSource: Identifiable, Equatable {
    /// MediaRemote's client bundle ID (e.g. Safari's WebKit audio process).
    let id: String
    let name: String
    /// Preferred first (a browser before its WebKit audio process).
    let bundleIDs: [String]
    let app: SourceApp?
    let isPlaying: Bool
    /// The system's active Now Playing app: the only one MediaRemote sends commands to.
    let isActive: Bool
    /// The process making the sound (Safari: its WebKit audio process), if known.
    let processID: pid_t?
}

/// The app that is playing, resolved from its bundle ID.
struct SourceApp: Equatable {
    /// Source icons are ordered by kind: music players, podcast apps, browsers, then the rest.
    enum Kind: Int, Comparable {
        case music, podcasts, browser, other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let bundleID: String
    let name: String
    let icon: NSImage
    let url: URL
    let kind: Kind

    /// Tries each ID in turn (e.g. Safari before its WebKit audio process).
    init?(bundleIDs: [String]) {
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            self.bundleID = bundleID
            self.url = url
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            icon = NSWorkspace.shared.icon(forFile: url.path)
            kind = Self.kind(of: bundleID, url: url, bundle: bundle)
            return
        }
        return nil
    }

    private static let musicApps: Set = [
        "com.apple.Music", "com.spotify.client", "com.tidal.desktop", "com.amazon.music",
        "com.deezer.deezer-desktop", "tv.plex.plexamp", "com.coppertino.Vox", "com.apple.iTunes",
    ]
    private static let podcastApps: Set = [
        "com.apple.podcasts", "au.com.shiftyjelly.podcasts", "fm.overcast.overcast", "co.supertop.Castro",
    ]

    private static func kind(of bundleID: String, url: URL, bundle: Bundle?) -> Kind {
        if musicApps.contains(bundleID)
            || bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String == "public.app-category.music" {
            return .music
        }
        if podcastApps.contains(bundleID) || bundleID.lowercased().contains("podcast") {
            return .podcasts
        }
        // A browser is anything registered to open web links.
        if let web = URL(string: "https://example.com"),
           NSWorkspace.shared.urlsForApplications(toOpen: web).contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            return .browser
        }
        return .other
    }

    static func == (lhs: SourceApp, rhs: SourceApp) -> Bool { lhs.bundleID == rhs.bundleID }
}
