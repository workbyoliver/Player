import CoreAudio
import Observation

/// Per-app volume levels. An app at 100% plays untouched; below that, its audio is
/// re-played through an `AppVolumeTap` at the chosen level.
@Observable
final class AppVolumes {
    /// 0...1 per source ID; missing means 100%.
    private(set) var levels: [String: Float] = [:]
    /// Shown under the slider when per-app volume can't work (e.g. permission denied).
    private(set) var problem: String?

    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    @ObservationIgnored private var sources: [String: PlayingSource] = [:]
    @ObservationIgnored private var outputListener: PropertyListener?
    @ObservationIgnored private var isRequestingPermission = false

    init() {
        // Taps play to a specific device, so follow the default output when it changes.
        outputListener = PropertyListener(object: .system, address: .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.rebuildTaps()
        }
    }

    func level(for source: PlayingSource) -> Float {
        levels[source.id] ?? 1
    }

    func setLevel(_ newValue: Float, for source: PlayingSource) {
        let value = min(max(newValue, 0), 1)
        if levels[source.id] != value { levels[source.id] = value }
        sources[source.id] = source
        apply(source.id)
    }

    func nudge(by delta: Float, for source: PlayingSource) {
        setLevel(level(for: source) + delta, for: source)
    }

    /// Keeps taps pointed at the right processes as apps start, quit and relaunch.
    func update(sources newSources: [PlayingSource]) {
        let current = Dictionary(newSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Array(levels.keys) where current[id] == nil {
            levels[id] = nil // the app is gone; start it fresh at 100% next time
            taps.removeValue(forKey: id)?.invalidate()
        }
        for (id, source) in current {
            let previous = sources[id]
            sources[id] = source
            if previous?.processID != source.processID {
                taps.removeValue(forKey: id)?.invalidate() // relaunched: tap the new process
            }
            if levels[id] != nil { apply(id) } // also catches apps that hadn't made a sound yet
        }
    }

    /// Gives every app its own audio back (on quit).
    func releaseAll() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    // MARK: - Private

    private func apply(_ id: String) {
        guard let source = sources[id] else { return }
        let value = levels[id] ?? 1
        if value >= 0.995 {
            taps.removeValue(forKey: id)?.invalidate() // 100%: let the app play normally
            return
        }
        if let tap = taps[id] {
            tap.level = value
            return
        }
        switch AudioCapturePermission.status {
        case .authorized:
            startTap(for: source, level: value)
        case .denied:
            permissionDenied()
        case .undetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                self.isRequestingPermission = false
                if granted {
                    self.problem = nil
                    for id in self.levels.keys { self.apply(id) }
                } else {
                    self.permissionDenied()
                }
            }
        }
    }

    private func startTap(for source: PlayingSource, level: Float) {
        let processes = Self.audioProcesses(for: source)
        // An app that hasn't made a sound yet has no audio process; update(sources:) retries.
        guard !processes.isEmpty,
              let outputUID = AudioObjectID.defaultOutputDevice.getString(.init(kAudioDevicePropertyDeviceUID))
        else { return }
        do {
            taps[source.id] = try AppVolumeTap(processes: processes, outputUID: outputUID, level: level)
            problem = nil
        } catch {
            levels[source.id] = nil
            problem = "Couldn't change \(source.name)'s volume: \(error)."
        }
    }

    private func permissionDenied() {
        releaseAll()
        levels.removeAll()
        problem = "To set app volumes, allow Player in System Settings › Privacy & Security › Screen & System Audio Recording."
    }

    private func rebuildTaps() {
        for id in Array(taps.keys) {
            taps.removeValue(forKey: id)?.invalidate()
            apply(id)
        }
    }

    /// The Core Audio process objects that make the source's sound: the process MediaRemote
    /// reports (Safari: its WebKit audio process) plus the app and its helpers (Chrome, Spotify).
    private static func audioProcesses(for source: PlayingSource) -> [AudioObjectID] {
        let appBundleID = source.bundleIDs.first ?? source.id
        return AudioObjectID.system
            .getArray(.init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
            .filter { process in
                if let pid = source.processID, process.get(.init(kAudioProcessPropertyPID), as: pid_t.self) == pid {
                    return true
                }
                guard let bundleID = process.getString(.init(kAudioProcessPropertyBundleID)) else { return false }
                return bundleID == appBundleID || bundleID.hasPrefix(appBundleID + ".")
            }
    }
}
