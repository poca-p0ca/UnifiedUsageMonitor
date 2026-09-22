import Foundation

/// Both quota endpoints are undocumented and can change shape without notice.
/// Keeping the last raw response on disk turns "the bar went blank" into a
/// one-file diagnosis.
enum DebugLog {
    private static let directory: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/UnifiedUsageMonitor")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func dump(_ data: Data, name: String) {
        let url = directory.appendingPathComponent("\(name).json")
        try? data.write(to: url, options: [.atomic])
    }

    static func note(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = directory.appendingPathComponent("monitor.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: [.atomic])
        }
    }
}
