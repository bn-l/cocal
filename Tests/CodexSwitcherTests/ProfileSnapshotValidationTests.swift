import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Profile snapshot identity validation", .serialized)
struct ProfileSnapshotValidationTests {

    private static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-snapshot-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String, email: String, exp: Date? = nil) throws -> String {
        let inner: [String: Any] = [
            "chatgpt_user_id": user,
            "chatgpt_account_id": account,
        ]
        var payload: [String: Any] = [
            "https://api.openai.com/auth": inner,
            "email": email,
        ]
        if let exp { payload["exp"] = exp.timeIntervalSince1970 }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    private static func auth(user: String, account: String, email: String, refreshToken: String) throws -> AuthJSON {
        let id = try idToken(user: user, account: account, email: email)
        let access = try idToken(user: user, account: account, email: email, exp: Date().addingTimeInterval(3600))
        return AuthJSON(
            tokens: AuthTokens(idToken: id, accessToken: access, refreshToken: refreshToken, accountID: account)
        )
    }

    @Test("PerProfile refuses to read a snapshot whose JWT belongs to a different imported profile")
    func perProfileRejectsMismatchedSnapshot() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let profile = Profile(
            id: "profile-a",
            label: "bnlgcp@gmail.com",
            dedupKey: "user-a::acct-a"
        )
        let wrongSnapshot = try Self.auth(
            user: "user-b",
            account: "acct-b",
            email: "keytrex@gmail.com",
            refreshToken: "rt-b"
        )
        try store.insert(profile, snapshot: wrongSnapshot)

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            expectedDedupKey: profile.dedupKey
        )

        await #expect(throws: ProfileSnapshotIdentityError.self) {
            _ = try await actor.usage()
        }
    }

    @Test("Capture-live does not overwrite an outgoing profile with another account's live auth.json")
    func captureLiveRejectsMismatchedOutgoingSnapshot() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let profile = Profile(
            id: "profile-a",
            label: "bnlgcp@gmail.com",
            dedupKey: "user-a::acct-a"
        )
        let originalSnapshot = try Self.auth(
            user: "user-a",
            account: "acct-a",
            email: "bnlgcp@gmail.com",
            refreshToken: "rt-a-original"
        )
        try store.insert(profile, snapshot: originalSnapshot)

        let liveURL = root.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let otherAccountLiveAuth = try Self.auth(
            user: "user-b",
            account: "acct-b",
            email: "keytrex@gmail.com",
            refreshToken: "rt-b-live"
        )
        try Snapshotter.write(otherAccountLiveAuth, to: liveURL)

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            expectedDedupKey: profile.dedupKey
        )

        await #expect(throws: ProfileSnapshotIdentityError.self) {
            try await actor.captureLive(from: liveURL)
        }

        let stored = try Snapshotter.read(store.snapshotURL(for: profile.id))
        #expect(stored.tokens?.refreshToken == "rt-a-original")
        #expect(try Snapshotter.dedupKey(for: stored) == profile.dedupKey)
    }
}
