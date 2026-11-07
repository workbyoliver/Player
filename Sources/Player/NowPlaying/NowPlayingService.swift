import AppKit
import Observation

/// Keeps the Now Playing helper running and publishes what it reports.
///
/// The helper is `/usr/bin/perl helper.pl MediaRemoteHelper.dylib` (see Helper/):
/// JSON lines come back on its stdout, commands go to its stdin.
@Observable
final class NowPlayingService {
    enum Command: String {
        case play, pause, toggle, next, prev
    }

    /// The selected source's track.
    private(set) var track: Track?
    private(set) var artwork: NSImage?
    private(set) var source: SourceApp?
    /// Every app with something in Now Playing, in MediaRemote's order.
    private(set) var sources: [PlayingSource] = []
    /// The source the panel shows: your pick, else the system's active player.
    private(set) var selectedSourceID: String?

    var selectedSource: PlayingSource? { sources.first { $0.id == selectedSourceID } }

    /// MediaRemote only delivers commands to the system's active player; other apps
    /// can be controlled only if they're scriptable (Music, Spotify).
    var canControl: Bool {
        guard let selectedSource else { return track != nil }
        return selectedSource.isActive || ScriptedPlayer(bundleIDs: selectedSource.bundleIDs) != nil
    }
    /// Colours for the panel's background, from the artwork (or the app icon without one).
    private(set) var palette = ArtworkPalette.neutral
    /// Set when the helper can't run or reports a problem.
    private(set) var problem: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var restartDelay: TimeInterval = 1
    @ObservationIgnored private var sourceBundleIDs: [String] = []
    @ObservationIgnored private var appCache: [[String]: SourceApp?] = [:]
    @ObservationIgnored private var reconcile: DispatchWorkItem?

    func start() {
        guard process == nil, !isStopping else { return }
        guard let resources = Bundle.main.resourceURL,
              case let script = resources.appending(path: "helper.pl"),
              case let library = resources.appending(path: "MediaRemoteHelper.dylib"),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: library.path)
        else {
            problem = "Helper files are missing. Build with `make build`."
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        let reader = HelperOutputReader { [weak self] message in
            // Main queue (not a Task) so messages are applied in order.
            DispatchQueue.main.async { self?.apply(message) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.feed(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.helperExited(process) }
        }

        do {
            try process.run()
        } catch {
            problem = "Couldn't start the Now Playing helper: \(error.localizedDescription)"
            scheduleRestart()
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    func stop() {
        isStopping = true
        try? input?.close() // the helper exits on stdin EOF
        process?.terminate()
    }

    func send(_ command: Command) {
        if let selectedSource, !selectedSource.isActive {
            guard let player = ScriptedPlayer(bundleIDs: selectedSource.bundleIDs) else { return }
            player.send(command)
        } else {
            write(command.rawValue)
        }
        guard command == .toggle || command == .play || command == .pause, var track else { return }
        // Flip the button right away; the helper confirms (or corrects) shortly after.
        track = track.settled(at: .now)
        track.isPlaying = command == .toggle ? !track.isPlaying : command == .play
        self.track = track
        scheduleReconcile()
    }

    func seek(to seconds: TimeInterval) {
        if let selectedSource, !selectedSource.isActive {
            guard let player = ScriptedPlayer(bundleIDs: selectedSource.bundleIDs) else { return }
            player.seek(to: seconds)
        } else {
            write("seek \(seconds)")
        }
        guard var track else { return }
        track.elapsed = seconds
        track.timestamp = .now
        self.track = track
        scheduleReconcile()
    }

    /// Shows (and controls) this source until it goes away or another app starts playing.
    func select(_ source: PlayingSource) {
        guard source.id != selectedSourceID else { return }
        selectedSourceID = source.id
        write("select \(source.id)")
    }

    // MARK: - Private

    private func write(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// If a command was ignored, no change notification arrives and the optimistic
    /// state would stick. Ask the helper to re-send the real state.
    private func scheduleReconcile() {
        reconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write("refresh") }
        reconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func apply(_ message: HelperMessage) {
        restartDelay = 1
        switch message {
        case .ready:
            problem = nil
        case .empty:
            track = nil
            artwork = nil
            source = nil
            sourceBundleIDs = []
            updatePalette()
        case let .track(newTrack, bundleIDs, artworkUpdate):
            if track != newTrack { track = newTrack }
            var visualsChanged = false
            switch artworkUpdate {
            case .unchanged: break
            case .cleared: artwork = nil; visualsChanged = true
            case let .image(data): artwork = NSImage(data: data); visualsChanged = true
            }
            if bundleIDs != sourceBundleIDs {
                sourceBundleIDs = bundleIDs
                source = app(for: bundleIDs)
                visualsChanged = true
            }
            if visualsChanged { updatePalette() }
        case let .sources(infos, selected):
            let newSources = infos.map { info in
                PlayingSource(
                    id: info.id,
                    name: info.name,
                    bundleIDs: info.bundleIDs,
                    app: app(for: info.bundleIDs),
                    isPlaying: info.isPlaying,
                    isActive: info.isActive,
                    processID: info.processID
                )
            }
            // Music players first, then podcasts, browsers and the rest; MediaRemote's order within each.
            let ordered = newSources.enumerated()
                .sorted { ($0.element.app?.kind ?? .other, $0.offset) < ($1.element.app?.kind ?? .other, $1.offset) }
                .map(\.element)
            if ordered != sources { sources = ordered }
            if selected != selectedSourceID { selectedSourceID = selected }
        case let .error(text):
            problem = text
        }
    }

    /// App name and icon lookups hit the disk, so remember them.
    private func app(for bundleIDs: [String]) -> SourceApp? {
        if let cached = appCache[bundleIDs] { return cached }
        let app = SourceApp(bundleIDs: bundleIDs)
        appCache[bundleIDs] = app
        return app
    }

    private func updatePalette() {
        let newPalette = (artwork ?? source?.icon).flatMap(ArtworkPalette.init(image:)) ?? .neutral
        if newPalette != palette { palette = newPalette }
    }

    private func helperExited(_ exited: Process) {
        guard exited === process else { return }
        process = nil
        input = nil
        if !isStopping { scheduleRestart() }
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }
}

// MARK: - Helper protocol

nonisolated enum ArtworkUpdate: Sendable {
    case unchanged, cleared, image(Data)
}

nonisolated struct SourceInfo: Sendable {
    let id: String
    let name: String
    /// Preferred first (a browser before its WebKit audio process).
    let bundleIDs: [String]
    let isPlaying: Bool
    let isActive: Bool
    let processID: pid_t?
}

nonisolated enum HelperMessage: Sendable {
    case ready
    case empty
    /// bundleIDs: preferred first (a browser before its WebKit audio process).
    case track(Track, bundleIDs: [String], artwork: ArtworkUpdate)
    case sources([SourceInfo], selected: String?)
    case error(String)

    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "ready":
            self = .ready
        case "empty":
            self = .empty
        case "error":
            self = .error(object["message"] as? String ?? "Unknown helper error")
        case "track":
            let duration = object["duration"] as? Double
            let track = Track(
                title: object["title"] as? String ?? "",
                artist: object["artist"] as? String ?? "",
                album: object["album"] as? String ?? "",
                duration: duration.flatMap { $0 > 0 ? $0 : nil },
                elapsed: object["elapsed"] as? Double ?? 0,
                timestamp: (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now,
                rate: object["rate"] as? Double ?? 0,
                isPlaying: object["playing"] as? Bool ?? false
            )
            let bundleIDs = [object["parentBundleId"], object["bundleId"]].compactMap { $0 as? String }
            let artwork: ArtworkUpdate
            if !object.keys.contains("artwork") {
                artwork = .unchanged
            } else if let base64 = object["artwork"] as? String, let data = Data(base64Encoded: base64) {
                artwork = .image(data)
            } else {
                artwork = .cleared
            }
            self = .track(track, bundleIDs: bundleIDs, artwork: artwork)
        case "sources":
            let entries = object["sources"] as? [[String: Any]] ?? []
            let sources = entries.compactMap { entry -> SourceInfo? in
                guard let id = entry["id"] as? String else { return nil }
                return SourceInfo(
                    id: id,
                    name: entry["name"] as? String ?? id,
                    bundleIDs: [entry["parentBundleId"] as? String, id].compactMap { $0 },
                    isPlaying: entry["playing"] as? Bool ?? false,
                    isActive: entry["active"] as? Bool ?? false,
                    processID: (entry["pid"] as? Int).map { pid_t($0) }
                )
            }
            self = .sources(sources, selected: object["selected"] as? String)
        default:
            return nil
        }
    }
}

/// Splits the helper's stdout into lines. Artwork lines can span many reads.
nonisolated final class HelperOutputReader: @unchecked Sendable {
    // Only touched from the pipe's readability handler, which FileHandle calls serially.
    private var buffer = Data()
    private let onMessage: @Sendable (HelperMessage) -> Void

    init(onMessage: @escaping @Sendable (HelperMessage) -> Void) {
        self.onMessage = onMessage
    }

    func feed(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = HelperMessage(line: line) { onMessage(message) }
        }
    }
}
