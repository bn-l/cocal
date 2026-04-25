import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Importer")
struct ImporterTests {

    private static func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeAuthJSON(at url: URL, dedupUser: String, dedupAccount: String, email: String?) throws {
        var payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": dedupUser,
                "chatgpt_account_id": dedupAccount,
            ]
        ]
        if let email { payload["email"] = email }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(b64url(header)).\(b64url(payloadData)).sig"

        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: dedupAccount))
        try Snapshotter.write(auth, to: url)
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("Fresh import creates a new profile with email-derived label")
    func importsNew() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "alice@example.com")

        let storeRoot = home.appendingPathComponent("profiles")
        let store = ProfileStore(rootDirectory: storeRoot)
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        let (outcome, _) = try importer.runImport()
        guard case let .imported(profile) = outcome else {
            #expect(Bool(false), "expected .imported"); return
        }
        #expect(profile.label == "alice@example.com")
        #expect(profile.dedupKey == "user-1::acct-1")
        #expect(store.loadAll().count == 1)
    }

    @Test("Duplicate import (same dedup key) returns .duplicate without creating a new profile")
    func detectsDuplicate() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "alice@example.com")

        let storeRoot = home.appendingPathComponent("profiles")
        let store = ProfileStore(rootDirectory: storeRoot)
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        _ = try importer.runImport()
        let (outcome2, _) = try importer.runImport()
        if case .duplicate = outcome2 {
            // pass
        } else {
            #expect(Bool(false), "expected .duplicate, got \(outcome2)")
        }
        #expect(store.loadAll().count == 1)
    }

    @Test("Throws .noLiveAuth when no auth.json exists anywhere")
    func failsWhenNoAuthFile() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        #expect(throws: Importer.ImportError.self) {
            _ = try importer.runImport()
        }
    }

    @Test("Throws .missingDedupClaims when id_token lacks the chatgpt_* claims")
    func failsWhenJWTLacksClaims() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        // Build a token without the OpenAI auth wrapper.
        let payloadData = try JSONSerialization.data(withJSONObject: ["email": "user@example.com"], options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(Self.b64url(header)).\(Self.b64url(payloadData)).sig"
        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: nil))
        try Snapshotter.write(auth, to: liveURL)

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)
        #expect(throws: Importer.ImportError.missingDedupClaims) {
            _ = try importer.runImport()
        }
    }
}
