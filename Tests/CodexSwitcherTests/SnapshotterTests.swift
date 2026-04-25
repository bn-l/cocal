import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Snapshotter file I/O")
struct SnapshotterTests {

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-tests-\(UUID().uuidString)")
            .appendingPathComponent("auth.json")
    }

    private static func sampleAuthJSON() -> AuthJSON {
        AuthJSON(
            tokens: AuthTokens(
                idToken: "header.eyJlbWFpbCI6ImFAYi5jb20ifQ.sig",
                accessToken: "access",
                refreshToken: "refresh",
                accountID: "acct"
            ),
            lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Atomic write produces a 0600 file we can round-trip")
    func writeRoundtripWithPermissions() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Snapshotter.write(Self.sampleAuthJSON(), to: url)

        // Permissions must be 0600 so we don't leak refresh tokens (PLAN.md §2.3).
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)

        let restored = try Snapshotter.read(url)
        #expect(restored.tokens?.refreshToken == "refresh")
    }

    @Test("read throws fileNotFound for a missing path")
    func readMissing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        #expect(throws: Snapshotter.Error.self) {
            _ = try Snapshotter.read(url)
        }
    }

    @Test("dedupKey extracts the chatgpt_user_id::chatgpt_account_id from the id_token")
    func dedupKeyExtraction() throws {
        // Build an id_token with the auth claim wrapper.
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "user-1",
                "chatgpt_account_id": "acct-1",
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(b64url(header)).\(b64url(payloadData)).sig"

        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: "acct-1"))
        let key = try Snapshotter.dedupKey(for: auth)
        #expect(key == "user-1::acct-1")
    }

    private func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
