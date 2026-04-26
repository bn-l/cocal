import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Migration")

/// One-shot migrations run during `CodexSwitcherApp.init`.
///
/// Earlier builds wrote `config.json` and `usage_data.json` under
/// `~/.config/codex-switcher/`. The canonical macOS location is
/// `~/Library/Application Support/codex-switcher/` (matching the profile store),
/// so we copy any stragglers over on first launch and leave the originals in
/// place — deleting them would be destructive if the user is running an older
/// build alongside.
enum Migration {
    static let appSupportDirectory: URL = defaultAppSupportDirectory()
    static let migratedFilenames = ["config.json", "usage_data.json"]

    static func defaultAppSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("codex-switcher", isDirectory: true)
    }

    static func defaultLegacyDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/codex-switcher", directoryHint: .isDirectory)
    }

    static func runIfNeeded() {
        run(appSupport: appSupportDirectory, legacy: defaultLegacyDirectory())
    }

    /// Test seam — run the same migration against arbitrary directories.
    static func run(appSupport: URL, legacy: URL, filenames: [String] = migratedFilenames) {
        ensureDirectory(appSupport)
        for name in filenames {
            copyIfMissing(filename: name, source: legacy, destination: appSupport)
        }
    }

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func copyIfMissing(filename: String, source: URL, destination: URL) {
        let src = source.appendingPathComponent(filename)
        let dst = destination.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path()) else { return }
        guard !fm.fileExists(atPath: dst.path()) else {
            logger.debug("Skip migrate \(filename, privacy: .public): destination already exists")
            return
        }
        do {
            try fm.copyItem(at: src, to: dst)
            logger.info("Migrated \(filename, privacy: .public) from \(src.path(), privacy: .public) to \(dst.path(), privacy: .public)")
        } catch {
            logger.error("Failed to migrate \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
