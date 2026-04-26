import Testing
import Foundation
@testable import CodexSwitcher

@Suite("DesktopAuthService")
struct DesktopAuthServiceTests {

    private static func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-auth-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func auth(refresh: String) throws -> AuthJSON {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "u",
                "chatgpt_account_id": "a",
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(b64url(header)).\(b64url(payloadData)).sig"
        return AuthJSON(tokens: AuthTokens(idToken: token, accessToken: token, refreshToken: refresh, accountID: "a"))
    }

    @Test("install writes auth.json at the resolver's canonical path and returns that URL")
    func installWritesAtCanonicalPath() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        let target = try svc.install(try Self.auth(refresh: "rt"))

        let expected = home.appendingPathComponent(".codex/auth.json").path
        #expect(target.path == expected)
        #expect(FileManager.default.fileExists(atPath: expected))
        let onDisk = try Snapshotter.read(target)
        #expect(onDisk.tokens?.refreshToken == "rt")
    }

    @Test("install respects CODEX_HOME via the resolver")
    func installRespectsCodexHome() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let resolver = AuthPathResolver(environment: ["CODEX_HOME": codexHome.path], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        let target = try svc.install(try Self.auth(refresh: "rt"))

        #expect(target.path == codexHome.appendingPathComponent("auth.json").path)
        // Default-path file must NOT have been created.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path))
    }

    @Test("install creates .bak from prior live file (recovery seam)")
    func backupCreatedOnInstallOverExisting() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        // First install — no prior file, no .bak.
        _ = try svc.install(try Self.auth(refresh: "first"))
        let target = home.appendingPathComponent(".codex/auth.json")
        let backup = target.appendingPathExtension("bak")
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        // Second install — should produce a .bak with the FIRST install's data.
        _ = try svc.install(try Self.auth(refresh: "second"))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let backedUp = try Snapshotter.read(backup)
        #expect(backedUp.tokens?.refreshToken == "first")
        let live = try Snapshotter.read(target)
        #expect(live.tokens?.refreshToken == "second")
    }

    @Test("install replaces a stale .bak from an earlier overwrite")
    func staleBackupGetsReplaced() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        _ = try svc.install(try Self.auth(refresh: "first"))
        _ = try svc.install(try Self.auth(refresh: "second"))
        // .bak now contains "first". A third install must replace it with "second"
        // (the previous live file), not append or fail.
        _ = try svc.install(try Self.auth(refresh: "third"))

        let backup = home.appendingPathComponent(".codex/auth.json").appendingPathExtension("bak")
        let backedUp = try Snapshotter.read(backup)
        #expect(backedUp.tokens?.refreshToken == "second")
    }

    @Test("install writes 0600 on the live file")
    func installSetsMode0600() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        let target = try svc.install(try Self.auth(refresh: "rt"))

        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test("install creates the canonical parent directory when missing (~/.codex doesn't exist on a fresh box)")
    func installCreatesParentDir() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Note: no .codex directory pre-created. The fresh-box scenario.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let svc = DesktopAuthService(resolver: resolver)
        let target = try svc.install(try Self.auth(refresh: "rt"))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
