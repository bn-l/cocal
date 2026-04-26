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

    @Test("User-supplied label overrides the email-derived default")
    func labelOverride() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "ignored@example.com")

        let storeRoot = home.appendingPathComponent("profiles")
        let store = ProfileStore(rootDirectory: storeRoot)
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        let (outcome, _) = try importer.runImport(label: "Work account")
        guard case let .imported(profile) = outcome else {
            #expect(Bool(false), "expected .imported"); return
        }
        #expect(profile.label == "Work account")
    }

    @Test("Empty/whitespace-only label falls back to email")
    func blankLabelFallsBack() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "alice@example.com")

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        let (outcome, _) = try importer.runImport(label: "   ")
        guard case let .imported(profile) = outcome else {
            #expect(Bool(false), "expected .imported"); return
        }
        #expect(profile.label == "alice@example.com")
    }

    @Test("Re-import with newer lastRefresh: emits .refreshed with the fresh auth data")
    func refreshedOutcome() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        // First import — stores the snapshot with no lastRefresh.
        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "alice@example.com")
        _ = try importer.runImport()

        // Pin stored snapshot to an old lastRefresh so the next import is unambiguously fresher.
        let storedID = store.loadAll().first!.id
        let storedURL = store.snapshotURL(for: storedID)
        var stored = try Snapshotter.read(storedURL)
        stored.lastRefresh = Date(timeIntervalSince1970: 1000)
        try Snapshotter.write(stored, to: storedURL)

        // Live snapshot bears a newer lastRefresh.
        var live = try Snapshotter.read(liveURL)
        live.tokens?.refreshToken = "FRESH"
        live.lastRefresh = Date(timeIntervalSince1970: 2000)
        try Snapshotter.write(live, to: liveURL)

        let (outcome, auth) = try importer.runImport()
        guard case .refreshed = outcome else {
            #expect(Bool(false), "expected .refreshed, got \(outcome)"); return
        }
        // The Importer no longer writes the snapshot directly — the caller
        // routes through PerProfile.importUpdate() to serialize with any
        // concurrent Warmer refresh. Verify the returned auth carries the
        // fresh token so the caller has the right data to pass along.
        #expect(auth.tokens?.refreshToken == "FRESH")
        // Stored snapshot should be untouched by the Importer.
        let after = try Snapshotter.read(storedURL)
        #expect(after.tokens?.refreshToken == "r", "Importer must not write; stored snapshot should still have the original token")
    }

    @Test("Re-import with older lastRefresh: still .duplicate, stored snapshot preserved")
    func duplicateWhenOlder() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        try Self.writeAuthJSON(at: liveURL, dedupUser: "user-1", dedupAccount: "acct-1", email: "alice@example.com")
        _ = try importer.runImport()

        let storedID = store.loadAll().first!.id
        let storedURL = store.snapshotURL(for: storedID)
        var stored = try Snapshotter.read(storedURL)
        stored.tokens?.refreshToken = "STORED"
        stored.lastRefresh = Date(timeIntervalSince1970: 5000)
        try Snapshotter.write(stored, to: storedURL)

        var live = try Snapshotter.read(liveURL)
        live.tokens?.refreshToken = "OLDER"
        live.lastRefresh = Date(timeIntervalSince1970: 3000)
        try Snapshotter.write(live, to: liveURL)

        let (outcome, _) = try importer.runImport()
        if case .duplicate = outcome {} else {
            #expect(Bool(false), "expected .duplicate, got \(outcome)")
        }
        let after = try Snapshotter.read(storedURL)
        #expect(after.tokens?.refreshToken == "STORED")
    }

    @Test("Live file is malformed JSON: throws .malformed")
    func malformedLiveFile() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: liveURL)

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        do {
            _ = try importer.runImport()
            #expect(Bool(false), "expected throw")
        } catch Importer.ImportError.malformed {
            // ok
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("Live file with no tokens object: throws .malformed")
    func liveFileMissingTokens() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Valid JSON, but no `tokens` field.
        try Data(#"{"OPENAI_API_KEY": null}"#.utf8).write(to: liveURL)

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        do {
            _ = try importer.runImport()
            #expect(Bool(false), "expected throw")
        } catch let Importer.ImportError.malformed(msg) {
            #expect(msg.contains("tokens"))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("planType from id_token claims propagates onto a freshly-imported profile")
    func planTypePropagates() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let liveURL = home.appendingPathComponent(".codex/auth.json")
        // Build a token that includes chatgpt_plan_type.
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "u",
                "chatgpt_account_id": "a",
                "chatgpt_plan_type": "pro_5x",
            ],
            "email": "alice@example.com",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(Self.b64url(header)).\(Self.b64url(payloadData)).sig"
        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: "a"))
        try Snapshotter.write(auth, to: liveURL)

        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let importer = Importer(resolver: resolver, store: store)

        let (outcome, _) = try importer.runImport()
        guard case let .imported(p) = outcome else {
            #expect(Bool(false), "expected .imported"); return
        }
        #expect(p.planType == "pro_5x")
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
