import CoreAudio
import Observation

/// The default output device's volume, kept live via CoreAudio listeners
/// (it follows the default device when you switch outputs elsewhere).
@Observable
final class VolumeService {
    /// nil when the device has no software volume (e.g. most HDMI outputs).
    private(set) var volume: Float?
    private(set) var isMuted = false

    @ObservationIgnored private var outputID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var defaultOutputListener: PropertyListener?
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []

    init() {
        defaultOutputListener = PropertyListener(object: .system, address: .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.followDefaultOutput()
        }
        followDefaultOutput()
    }

    func setVolume(_ newValue: Float) {
        let value = min(max(newValue, 0), 1)
        guard outputID.set(.virtualMainVolume, to: Float32(value)) else { return }
        if value > 0, isMuted {
            outputID.set(.init(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), to: UInt32(0))
        }
        refresh()
    }

    func nudgeVolume(by delta: Float) {
        guard let volume else { return }
        setVolume(volume + delta)
    }

    // MARK: - Private

    private func followDefaultOutput() {
        let current = AudioObjectID.defaultOutputDevice
        if current != outputID {
            outputID = current
            deviceListeners.forEach { $0.remove() }
            let output = kAudioObjectPropertyScopeOutput
            let addresses: [AudioObjectPropertyAddress] = [
                .virtualMainVolume,
                .init(kAudioDevicePropertyVolumeScalar, scope: output),
                .init(kAudioDevicePropertyVolumeScalar, scope: output, element: 1),
                .init(kAudioDevicePropertyVolumeScalar, scope: output, element: 2),
                .init(kAudioDevicePropertyMute, scope: output),
            ]
            deviceListeners = addresses.compactMap { address in
                PropertyListener(object: current, address: address) { [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        let newVolume = outputID.isSettable(.virtualMainVolume) ? outputID.get(.virtualMainVolume, as: Float32.self) : nil
        let muted = outputID.get(.init(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), as: UInt32.self) == 1
        if newVolume != volume { volume = newVolume }
        if muted != isMuted { isMuted = muted }
    }
}

