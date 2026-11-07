import CoreAudio
import Foundation

/// Plays one app's audio at a chosen level, using a Core Audio process tap:
/// the app is muted at the source while tapped, and a private aggregate device
/// (tap in, current output device out) re-plays it scaled by `level`.
///
/// When this object goes away the tap is destroyed and the app plays normally again;
/// macOS also destroys private taps if Player quits or crashes.
final class AppVolumeTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// [0] the level set here (read on the audio thread; an aligned Float32 load/store is atomic),
    /// [1] the level the audio thread last played at, for ramping.
    private let gain: UnsafeMutablePointer<Float32>
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isLive = false

    var level: Float {
        get { gain[0] }
        set { gain[0] = min(max(newValue, 0), 1) }
    }

    init(processes: [AudioObjectID], outputUID: String, level: Float) throws {
        gain = .allocate(capacity: 2)
        gain.initialize(repeating: min(max(level, 0), 1), count: 2)
        do {
            try start(processes: processes, outputUID: outputUID)
        } catch {
            invalidate()
            throw error
        }
    }

    isolated deinit {
        invalidate() // stops the audio thread before the gain it reads is freed
        gain.deallocate()
    }

    /// Stops re-playing and gives the app its own audio back. Safe to call twice.
    func invalidate() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            if isLive { AudioDeviceStop(aggregateID, ioProcID) } // returns once the IOProc has stopped
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        isLive = false
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Setup

    private func start(processes: [AudioObjectID], outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Player app volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check("Creating the tap", AudioHardwareCreateProcessTap(description, &tapID))

        // The tap's stereo mixdown arrives interleaved (one buffer) or one buffer per channel.
        let format = tapID.get(.init(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)
        let channels = Int(format?.mChannelsPerFrame ?? 2)
        let nonInterleaved = (format?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved != 0

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Player app volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true, // the tap and the output run on different clocks
            ]],
        ]
        try check("Creating the output device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let block = Self.renderBlock(gain: gain, tapChannels: channels, tapIsNonInterleaved: nonInterleaved)
        try check("Creating the audio callback", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block))
        try check("Starting playback", AudioDeviceStart(aggregateID, ioProcID))
        isLive = true
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    // MARK: - Audio thread

    /// The real-time callback: copies the tap's audio to the output, scaled by the gain.
    /// No allocation, locks or Objective-C in here. Built outside the main actor so Swift
    /// doesn't attach main-thread checks to a closure the audio thread calls.
    nonisolated private static func renderBlock(
        gain: UnsafeMutablePointer<Float32>,
        tapChannels: Int,
        tapIsNonInterleaved: Bool
    ) -> AudioDeviceIOBlock {
        return { _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            // The tap's buffers come after any input streams of the output device itself
            // (e.g. a headset microphone), so read from the end of the list.
            let tapBufferCount = tapIsNonInterleaved ? tapChannels : 1
            let firstTapBuffer = inputs.count - tapBufferCount
            var tapFrames = 0
            if firstTapBuffer >= 0 {
                let first = inputs[firstTapBuffer]
                let samplesPerFrame = tapIsNonInterleaved ? 1 : max(Int(first.mNumberChannels), 1)
                tapFrames = Int(first.mDataByteSize) / (MemoryLayout<Float32>.size * samplesPerFrame)
            }

            // Ramp from the last level to the new one across the buffer, so dragging doesn't crackle.
            let target = gain[0]
            let currentGain = gain[1]
            var outputChannelBase = 0
            for buffer in outputs {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0 else { continue }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
                let step = frames > 0 ? (target - currentGain) / Float32(frames) : 0
                var level = currentGain
                for frame in 0..<frames {
                    level += step
                    for channel in 0..<channels {
                        let tapChannel = outputChannelBase + channel
                        var sample: Float32 = 0
                        if frame < tapFrames, tapChannel < tapChannels, firstTapBuffer >= 0 {
                            if tapIsNonInterleaved {
                                sample = inputs[firstTapBuffer + tapChannel].mData?
                                    .assumingMemoryBound(to: Float32.self)[frame] ?? 0
                            } else {
                                sample = inputs[firstTapBuffer].mData?
                                    .assumingMemoryBound(to: Float32.self)[frame * tapChannels + tapChannel] ?? 0
                            }
                        }
                        out[frame * channels + channel] = sample * level
                    }
                }
                outputChannelBase += channels
            }
            gain[1] = target
        }
    }
}
