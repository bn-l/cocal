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
    static let appSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("codex-switcher", isDirectory: true)
    }()

    private static let legacyDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".config/codex-switcher", directoryHint: .isDirectory)

    static func runIfNeeded() {
        ensureAppSupportDirectory()
        copyIfMissing(filename: "config.json")
        copyIfMissing(filename: "usage_data.json")
    }

    private static func ensureAppSupportDirectory() {
        try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    }

    private static func copyIfMissing(filename: String) {
        let source = legacyDirectory.appendingPathComponent(filename)
        let destination = appSupportDirectory.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path()) else { return }
        guard !fm.fileExists(atPath: destination.path()) else {
            logger.debug("Skip migrate \(filename, privacy: .public): destination already exists")
            return
        }
        do {
            try fm.copyItem(at: source, to: destination)
            logger.info("Migrated \(filename, privacy: .public) from \(source.path(), privacy: .public) to \(destination.path(), privacy: .public)")
        } catch {
            logger.error("Failed to migrate \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
