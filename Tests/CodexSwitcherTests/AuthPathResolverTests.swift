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

    @Test("CODEX_HOME wins over every other path")
    func codexHomePrecedence() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent("custom-codex")
        try Self.touch(codexHome.appendingPathComponent("auth.json"))
        try Self.touch(home.appendingPathComponent(".codex/auth.json"))

        let resolver = AuthPathResolver(
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home
        )
        #expect(resolver.canonicalReadPath()?.path == codexHome.appendingPathComponent("auth.json").path)
    }

    @Test("XDG_CONFIG_HOME falls in second when CODEX_HOME absent")
    func xdgFallback() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let xdg = home.appendingPathComponent("xdg")
        try Self.touch(xdg.appendingPathComponent("codex/auth.json"))
        try Self.touch(home.appendingPathComponent(".codex/auth.json"))

        let resolver = AuthPathResolver(
            environment: ["XDG_CONFIG_HOME": xdg.path],
            homeDirectory: home
        )
        #expect(resolver.canonicalReadPath()?.path == xdg.appendingPathComponent("codex/auth.json").path)
    }

    @Test("Falls back to ~/.codex when nothing else is set")
    func dotCodexFallback() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.touch(home.appendingPathComponent(".codex/auth.json"))

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.canonicalReadPath()?.path == home.appendingPathComponent(".codex/auth.json").path)
    }

    @Test("canonicalWritePath defaults to ~/.codex/auth.json when nothing exists")
    func writeFallback() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        #expect(resolver.canonicalReadPath() == nil)
        #expect(resolver.canonicalWritePath().path == home.appendingPathComponent(".codex/auth.json").path)
    }

    @Test("hasStraysBesidesCanonical surfaces multi-location scenarios")
    func detectsStrays() throws {
        let home = Self.makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexHome = home.appendingPathComponent("custom-codex")
        try Self.touch(codexHome.appendingPathComponent("auth.json"))
        try Self.touch(home.appendingPathComponent(".codex/auth.json"))

        let resolver = AuthPathResolver(
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home
        )
        #expect(resolver.hasStraysBesidesCanonical())
    }
}
