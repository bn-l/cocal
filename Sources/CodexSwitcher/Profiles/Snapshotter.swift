import Foundation

/// Pure read/write helpers for `auth.json` files — no profile state, no locking.
/// All concurrency control happens at the `PerProfile` actor layer one level up.
public enum Snapshotter {
    public enum Error: Swift.Error, Equatable {
        case fileNotFound(URL)
        case unreadable(URL, String)
        case malformedJSON(String)
        case missingTokens
        case writeFailure(String)
    }

    /// Read and decode an `auth.json` from disk.
    public static func read(_ url: URL) throws -> AuthJSON {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Error.unreadable(url, String(describing: error))
        }
        do {
            return try backendJSONDecoder().decode(AuthJSON.self, from: data)
        } catch {
            throw Error.malformedJSON(String(describing: error))
        }
    }

    /// Atomically write `auth.json` and chmod 600. Atomic on macOS (PLAN.md §3.1):
    /// `Data.write(.atomic)` writes via a temp sibling and renames; the rename is
    /// where the on-disk transition happens.
    public static func write(_ auth: AuthJSON, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(auth)
        } catch {
            throw Error.writeFailure("encode: \(error)")
        }

        // Make sure the parent directory exists. Codex's default
        // `~/.codex/` may not yet exist on a fresh box.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw Error.writeFailure("write: \(error)")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Error.writeFailure("chmod 600: \(error)")
        }
    }

    /// Extract the dedup key from an auth.json's `id_token`. The dedup key is what
    /// the import flow uses to recognize a profile we've already stored, even after
    /// the `auth.json` bytes have rotated through dozens of refreshes.
    public static func dedupKey(for auth: AuthJSON) throws -> String {
        guard let tokens = auth.tokens else { throw Error.missingTokens }
        let claims = try JWT.decode(tokens.idToken)
        guard let key = claims.dedupKey else {
            throw Error.malformedJSON("id_token missing chatgpt_user_id or chatgpt_account_id")
        }
        return key
    }
}
