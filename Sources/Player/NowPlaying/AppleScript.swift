import Foundation

/// Runs AppleScript through osascript, so a slow app or a permission prompt never blocks
/// the UI. Values are passed as arguments (`item n of argv`), never spliced into the source.
enum AppleScript {
    static func run(_ lines: [String], arguments: [String] = []) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv"] + lines.flatMap { ["-e", $0] } + ["-e", "end run"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
