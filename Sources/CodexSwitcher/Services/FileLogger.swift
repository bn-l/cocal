import Foundation
import OSLog

/// Append-only file logger that activates when verbose logging is toggled on.
///
/// Each line is `ISO-8601\tCATEGORY\tMESSAGE\n`. The file lives at
/// `~/Library/Application Support/codex-switcher/debug.log` and is rotated
/// when it exceeds `maxBytes` (old content is truncated, not archived).
///
/// Thread-safe via a serial `DispatchQueue`. All writes are synchronous
/// (`write(2)`) so lines are flushed immediately — no buffering to lose on crash.
public final class FileLogger: Sendable {
    public static let shared = FileLogger()

    /// 2 MB cap — enough for days of 5-minute polls, small enough to open in any editor.
    static let maxBytes = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.bn-l.codex-switcher.file-logger")
    let url: URL
    private let osLogger = Logger(subsystem: "com.bn-l.codex-switcher", category: "FileLogger")
    private let isEnabled: @Sendable () -> Bool

    public init(
        url: URL? = nil,
        isEnabled: (@Sendable () -> Bool)? = nil
    ) {
        self.url = url ?? Migration.appSupportDirectory.appendingPathComponent("debug.log")
        self.isEnabled = isEnabled ?? { AppConfig.load().verboseLogging }
    }

    public func log(_ category: String, _ message: String) {
        guard isEnabled() else { return }
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let line = "\(timestamp)\t\(category)\t\(message)\n"
        queue.async { [url, osLogger] in
            Self.ensureParent(url)
            Self.rotateIfNeeded(url)
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    osLogger.error("FileLogger: can't open \(url.path, privacy: .public)")
                    return
                }
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Drain the serial queue — ensures all pending writes are flushed.
    /// Test-only; production code never needs to call this.
    func flush() {
        queue.sync {}
    }

    private static func ensureParent(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return }
        // Truncate by keeping the last half.
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes / 2)
        // Find the first newline in the kept portion so we don't start mid-line.
        if let newline = keep.firstIndex(of: UInt8(ascii: "\n")) {
            let clean = keep.suffix(from: keep.index(after: newline))
            try? Data(clean).write(to: url, options: .atomic)
        } else {
            try? Data(keep).write(to: url, options: .atomic)
        }
    }
}

// MARK: - Convenience global

/// Shorthand used at every log site: `flog("Monitor", "Poll ok: ...")`
/// No-ops instantly when verbose logging is off (the `enabled` check is the first thing).
public func flog(_ category: String, _ message: String) {
    FileLogger.shared.log(category, message)
}
