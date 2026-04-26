import Foundation

/// Where Codex looks for `auth.json` on disk. We use a single canonical path —
/// `$CODEX_HOME/auth.json` if `CODEX_HOME` is set, otherwise `~/.codex/auth.json`.
/// Codex itself uses this exact resolution; legacy non-canonical paths are not
/// our problem.
public struct AuthPathResolver: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// The single canonical path. Always defined — file may or may not exist.
    public var canonicalPath: URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(filePath: codexHome).appendingPathComponent("auth.json")
        }
        return homeDirectory.appendingPathComponent(".codex/auth.json")
    }

    /// Canonical path for *reads*: the file if it exists, else `nil` (means
    /// "user hasn't run `codex login` yet").
    public func canonicalReadPath(fileManager: FileManager = .default) -> URL? {
        let url = canonicalPath
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Canonical path for *writes*: always the same single path.
    public func canonicalWritePath(fileManager: FileManager = .default) -> URL {
        canonicalPath
    }
}
