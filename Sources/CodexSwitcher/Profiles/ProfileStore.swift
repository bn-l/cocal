import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "ProfileStore")

/// On-disk catalog of imported profiles. Layout under the app's support directory:
///
///   profiles/
///     <profileID>/
///       metadata.json   ← `Profile` struct (label, dedupKey, last warm cache, …)
///       auth.json       ← snapshot, mode 0600, owned by the per-profile actor
///
/// The store itself only manages the *catalog* — it does not read or write the
/// `auth.json` files; the per-profile actors do. That keeps concurrent imports
/// from racing with concurrent warms or switches.
public final class ProfileStore: @unchecked Sendable {
    public let rootDirectory: URL
    private let queue = DispatchQueue(label: "com.bn-l.codex-switcher.ProfileStore")

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    /// Convenience: the canonical store under `~/Library/Application Support/codex-switcher/profiles/`.
    public static func defaultLocation() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("codex-switcher/profiles", isDirectory: true)
    }

    /// Path to a profile's directory.
    public func directory(for profileID: String) -> URL {
        rootDirectory.appendingPathComponent(profileID, isDirectory: true)
    }

    public func snapshotURL(for profileID: String) -> URL {
        directory(for: profileID).appendingPathComponent("auth.json")
    }

    public func metadataURL(for profileID: String) -> URL {
        directory(for: profileID).appendingPathComponent("metadata.json")
    }

    public func loadAll() -> [Profile] {
        queue.sync { _loadAll() }
    }

    public func loadByDedupKey(_ key: String) -> Profile? {
        loadAll().first(where: { $0.dedupKey == key })
    }

    /// Persist a new profile and its initial `auth.json` snapshot.
    public func insert(_ profile: Profile, snapshot: AuthJSON) throws {
        try queue.sync {
            let dir = directory(for: profile.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Snapshotter.write(snapshot, to: snapshotURL(for: profile.id))
            try writeMetadata(profile)
        }
    }

    public func updateMetadata(_ profile: Profile) throws {
        try queue.sync { try writeMetadata(profile) }
    }

    public func remove(_ profileID: String) throws {
        try queue.sync {
            let dir = directory(for: profileID)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        }
    }

    // MARK: - Private (run inside queue)

    private func _loadAll() -> [Profile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { dir -> Profile? in
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL) else { return nil }
            do {
                return try decoder.decode(Profile.self, from: data)
            } catch {
                logger.warning("Skipping malformed metadata at \(metaURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func writeMetadata(_ profile: Profile) throws {
        let dir = directory(for: profile.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        try data.write(to: metadataURL(for: profile.id), options: [.atomic])
    }
}
