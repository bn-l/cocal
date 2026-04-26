import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "DesktopAuth")

/// Writes an `auth.json` to the canonical Codex path so a freshly-launched `codex`
/// CLI / Codex.app will pick it up. PLAN.md §2.3 — write to **only** the
/// highest-precedence existing path, never fan out.
public struct DesktopAuthService: Sendable {
    public let resolver: AuthPathResolver

    public init(resolver: AuthPathResolver = AuthPathResolver()) {
        self.resolver = resolver
    }

    /// Install `auth` at the canonical Codex path. Returns the URL we wrote to.
    /// A `.bak` of any pre-existing live file is created on a best-effort basis.
    @discardableResult
    public func install(_ auth: AuthJSON) throws -> URL {
        let target = resolver.canonicalWritePath()
        let backupURL = target.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: target, to: backupURL)
        }
        try Snapshotter.write(auth, to: target)
        logger.info("Installed auth.json at=\(target.path, privacy: .public)")
        return target
    }
}
