import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Migration")
struct MigrationTests {

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    @Test("Copies legacy files into app support when destination is empty")
    func copiesLegacyFiles() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport")
        let legacy = root.appendingPathComponent("Legacy")

        try Self.write("{\"config\":1}", to: legacy.appendingPathComponent("config.json"))
        try Self.write("[\"poll\"]", to: legacy.appendingPathComponent("usage_data.json"))

        Migration.run(appSupport: appSupport, legacy: legacy)

        let configCopy = try String(contentsOf: appSupport.appendingPathComponent("config.json"), encoding: .utf8)
        let usageCopy = try String(contentsOf: appSupport.appendingPathComponent("usage_data.json"), encoding: .utf8)
        #expect(configCopy == "{\"config\":1}")
        #expect(usageCopy == "[\"poll\"]")
    }

    @Test("Does not overwrite existing destination files")
    func preservesExistingDestination() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport")
        let legacy = root.appendingPathComponent("Legacy")

        try Self.write("{\"new\":true}", to: appSupport.appendingPathComponent("config.json"))
        try Self.write("{\"old\":true}", to: legacy.appendingPathComponent("config.json"))

        Migration.run(appSupport: appSupport, legacy: legacy)

        let kept = try String(contentsOf: appSupport.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(kept == "{\"new\":true}")
    }

    @Test("Creates app support directory if missing")
    func createsAppSupportDir() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("FreshAppSupport")
        let legacy = root.appendingPathComponent("Legacy")
        // No legacy files at all — migration should still create the dir.

        Migration.run(appSupport: appSupport, legacy: legacy)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: appSupport.path(), isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test("Leaves the legacy file in place after copying")
    func legacyFileRemains() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport")
        let legacy = root.appendingPathComponent("Legacy")
        let legacyConfig = legacy.appendingPathComponent("config.json")

        try Self.write("{\"x\":1}", to: legacyConfig)

        Migration.run(appSupport: appSupport, legacy: legacy)

        #expect(FileManager.default.fileExists(atPath: legacyConfig.path()))
    }

    @Test("Idempotent: second run is a no-op")
    func idempotent() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let appSupport = root.appendingPathComponent("AppSupport")
        let legacy = root.appendingPathComponent("Legacy")

        try Self.write("{\"v\":1}", to: legacy.appendingPathComponent("config.json"))
        Migration.run(appSupport: appSupport, legacy: legacy)

        // Mutate the destination to detect any subsequent overwrite.
        try Self.write("{\"v\":2}", to: appSupport.appendingPathComponent("config.json"))

        Migration.run(appSupport: appSupport, legacy: legacy)
        let kept = try String(contentsOf: appSupport.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(kept == "{\"v\":2}")
    }
}
