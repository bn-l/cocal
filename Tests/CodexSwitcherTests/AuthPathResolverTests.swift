import Testing
import Foundation
@testable import CodexSwitcher

@Suite("AuthPathResolver")
struct AuthPathResolverTests {

    /// Use a temp HOME so tests are hermetic and never read the developer's real
    /// `~/.codex/auth.json`.
    private static func makeFakeHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)
    }

    @Test("CODEX_HOME determines the canonical path when set")
    func codexHomeOverride() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent("custom-codex")
        try Self.touch(codexHome.appendingPathComponent("auth.json"))

        let resolver = AuthPathResolver(
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home
        )
        #expect(resolver.canonicalPath.path == codexHome.appendingPathComponent("auth.json").path)
        #expect(resolver.canonicalReadPath()?.path == codexHome.appendingPathComponent("auth.json").path)
        #expect(resolver.canonicalWritePath().path == codexHome.appendingPathComponent("auth.json").path)
    }

    @Test("Defaults to ~/.codex/auth.json when CODEX_HOME is unset")
    func defaultPath() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.touch(home.appendingPathComponent(".codex/auth.json"))

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.canonicalReadPath()?.path == home.appendingPathComponent(".codex/auth.json").path)
    }

    @Test("Empty CODEX_HOME falls back to ~/.codex/auth.json")
    func emptyCodexHome() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: ["CODEX_HOME": ""], homeDirectory: home)
        #expect(resolver.canonicalPath.path == home.appendingPathComponent(".codex/auth.json").path)
    }

    @Test("canonicalReadPath returns nil when nothing exists")
    func readPathNilWhenAbsent() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.canonicalReadPath() == nil)
        #expect(resolver.canonicalWritePath().path == home.appendingPathComponent(".codex/auth.json").path)
    }
}
