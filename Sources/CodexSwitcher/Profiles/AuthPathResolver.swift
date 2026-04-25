import Foundation

/// Where Codex looks for `auth.json` on disk. The order matches AI-Plan-Monitor's
/// `auth_path_candidates` (PLAN.md §2.3): on **read** we take the first that exists;
/// on **write** we target the canonical (highest-precedence existing) path only,
/// because writing to all of them blindly can stomp credentials for an unrelated
/// account.
public struct AuthPathResolver: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// All path candidates in precedence order, regardless of whether they exist.
    public var candidates: [URL] {
        var urls: [URL] = []
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            urls.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            urls.append(URL(fileURLWithPath: xdg).appendingPathComponent("codex/auth.json"))
        }
        urls.append(homeDirectory.appendingPathComponent(".config/codex/auth.json"))
        urls.append(homeDirectory.appendingPathComponent(".codex/auth.json"))
        return urls
    }

    /// Existing candidates only, in the same precedence order. Empty when no auth.json
    /// is present anywhere — that's the "user hasn't run `codex login` yet" state.
    public func existingCandidates(fileManager: FileManager = .default) -> [URL] {
        candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// The canonical path for *reads* — first existing candidate, or `nil` if none.
    public func canonicalReadPath(fileManager: FileManager = .default) -> URL? {
        existingCandidates(fileManager: fileManager).first
    }

    /// The canonical path for *writes*. Per PLAN.md §2.3 we never fan out across all
    /// existing candidates; instead we write to whichever one Codex itself would read.
    /// If nothing exists yet, fall back to `~/.codex/auth.json` (the documented default).
    public func canonicalWritePath(fileManager: FileManager = .default) -> URL {
        if let existing = canonicalReadPath(fileManager: fileManager) { return existing }
        return homeDirectory.appendingPathComponent(".codex/auth.json")
    }

    /// `true` when more than one candidate exists, signalling the user has stale
    /// auth.json files lying around and we should surface the consolidation prompt
    /// (PLAN.md §2.3).
    public func hasStraysBesidesCanonical(fileManager: FileManager = .default) -> Bool {
        existingCandidates(fileManager: fileManager).count > 1
    }
}
