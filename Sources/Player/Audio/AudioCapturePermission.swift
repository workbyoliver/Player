import Foundation

/// The "Screen & System Audio Recording" permission that process taps need.
///
/// There's no public API to check or request it ahead of time, and a tap created without
/// it delivers silence while still muting the app. So this uses TCC's private functions
/// (as open-source tap apps do) to ask first and only tap once allowed.
enum AudioCapturePermission {
    enum Status { case authorized, denied, undetermined }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return .undetermined }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt (first time only); `completion` runs on the main thread.
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessRequest") }) else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil, onMain(completion))
    }

    /// Built outside the main actor: TCC calls back on its own queue.
    nonisolated private static func onMain(_ completion: @escaping @MainActor (Bool) -> Void) -> @convention(block) (Bool) -> Void {
        { granted in DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } } }
    }
}
