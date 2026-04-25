import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "CodexConfig")

/// Classifies and (when asked) rewrites `~/.codex/config.toml`'s
/// `cli_auth_credentials_store` setting (PLAN.md §2.3 "Keyring vs file storage").
///
/// On macOS, `auto` and an absent setting both resolve to keyring (since
/// Security.framework is always available), so we treat them all as needing
/// the file-mode prompt before swaps can work.
public struct CodexConfig: Sendable {
    public enum StorageMode: Equatable, Sendable {
        case file
        case keyring
        case auto
        case unset

        /// True when swaps cannot reliably affect a running Codex CLI / Codex.app
        /// because credentials live in the Keychain rather than `~/.codex/auth.json`.
        public var needsFileMode: Bool {
            switch self {
            case .file: return false
            case .keyring, .auto, .unset: return true
            }
        }
    }

    public let configURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            self.configURL = URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")
        } else {
            self.configURL = homeDirectory.appendingPathComponent(".codex/config.toml")
        }
    }

    public init(configURL: URL) {
        self.configURL = configURL
    }

    public func detectMode() -> StorageMode {
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .unset
        }
        return Self.classify(raw)
    }

    /// Rewrite the config to set `cli_auth_credentials_store = "file"`. Preserves
    /// surrounding comments and other keys by operating at the line level rather
    /// than full-document TOML reparse.
    public func switchToFileMode() throws {
        let existing: String
        if FileManager.default.fileExists(atPath: configURL.path) {
            existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        } else {
            existing = ""
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let rewritten = Self.rewriteFileMode(existing)
        try rewritten.data(using: .utf8)!.write(to: configURL, options: .atomic)
        logger.info("Rewrote \(configURL.path, privacy: .public) to cli_auth_credentials_store=\"file\"")
    }

    // MARK: - Pure helpers (testable)

    static func classify(_ raw: String) -> StorageMode {
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            guard let value = extractValue(line: trimmed, key: "cli_auth_credentials_store") else { continue }
            switch value.lowercased() {
            case "file": return .file
            case "keyring": return .keyring
            case "auto": return .auto
            default: return .unset
            }
        }
        return .unset
    }

    static func rewriteFileMode(_ existing: String) -> String {
        let newline: Character = "\n"
        let lines = existing.split(separator: newline, omittingEmptySubsequences: false)
        var output: [String] = []
        var replaced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"),
               extractValue(line: trimmed, key: "cli_auth_credentials_store") != nil {
                output.append("cli_auth_credentials_store = \"file\"")
                replaced = true
            } else {
                output.append(String(line))
            }
        }
        if !replaced {
            // Insert at top-level (before the first table header) so the key
            // doesn't accidentally get scoped to a `[section]`.
            var insertIndex = output.count
            for (i, line) in output.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    insertIndex = i
                    break
                }
            }
            output.insert("cli_auth_credentials_store = \"file\"", at: insertIndex)
        }
        var joined = output.joined(separator: String(newline))
        if !joined.hasSuffix(String(newline)) {
            joined.append(newline)
        }
        return joined
    }

    private static func extractValue(line: String, key: String) -> String? {
        guard let eq = line.range(of: "=") else { return nil }
        let lhs = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
        guard lhs == key else { return nil }
        var rhs = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
        if let comment = rhs.range(of: "#") {
            rhs = String(rhs[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 {
            return String(rhs.dropFirst().dropLast())
        }
        return rhs.isEmpty ? nil : rhs
    }
}
