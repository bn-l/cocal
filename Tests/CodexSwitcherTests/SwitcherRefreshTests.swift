import Testing
import Foundation
@testable import CodexSwitcher

/// Regression: user switched to a profile whose credentials had been revoked
/// (they logged out of that ChatGPT account). The Switcher installed the stale
/// tokens into ~/.codex/auth.json without attempting a refresh first, bricking
/// Codex (stuck on splash screen until manual logout+re-login).
///
/// The fix: Switcher.switchTo() must call refreshIfNeeded() on the incoming
/// actor BEFORE installing. If the refresh fails (expired, revoked, exhausted),
/// the switch aborts and the live auth.json is left untouched.
@Suite("Switcher — pre-install refresh gate", .serialized)
struct SwitcherRefreshTests {

    private static func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-refresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String, exp: Date? = nil) throws -> String {
        var payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": user,
                "chatgpt_account_id": account,
            ] as [String: Any],
        ]
        if let exp { payload["exp"] = exp.timeIntervalSince1970 }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    /// When incoming profile's tokens are expired and the refresh is revoked,
    /// switchTo must throw — NOT install the stale tokens at the live path.
    @Test("Switch aborts when incoming refresh token is revoked")
    func switchAbortsOnRevokedRefresh() async throws {
        MockURLProtocol.acquireGate()
        defer { MockURLProtocol.releaseGate() }

        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let liveURL = codexDir.appendingPathComponent("auth.json")

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: home.appendingPathComponent("active-slot.json"))

        // Profile A (outgoing, currently active) — valid tokens, non-expired
        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", exp: Date().addingTimeInterval(3600))
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: "at-A", refreshToken: "rt-A", accountID: "acct-A"))
        let profileA = Profile(label: "A", dedupKey: "user-A::acct-A")
        try store.insert(profileA, snapshot: authA)

        // Profile B (incoming) — EXPIRED access token (exp in the past)
        let tokenB = try Self.idToken(user: "user-B", account: "acct-B", exp: Date().addingTimeInterval(-3600))
        let authB = AuthJSON(tokens: AuthTokens(idToken: tokenB, accessToken: "at-B-expired", refreshToken: "rt-B-revoked", accountID: "acct-B"))
        let profileB = Profile(label: "B", dedupKey: "user-B::acct-B")
        try store.insert(profileB, snapshot: authB)

        // Live auth.json belongs to A
        try Snapshotter.write(authA, to: liveURL)
        try slotStore.setActiveID(profileA.id)

        // Mock: refresh endpoint returns "invalid_grant" (user logged out → revoked)
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(
                url: request.url!,
                status: 403,
                body: #"{"error":"invalid_grant","error_description":"refresh token revoked"}"#
            )
        }

        let refresher = TokenRefresher(session: session)
        let actorA = PerProfile(profileID: profileA.id, snapshotURL: store.snapshotURL(for: profileA.id))
        let actorB = PerProfile(profileID: profileB.id, snapshotURL: store.snapshotURL(for: profileB.id), refresher: refresher)

        let switcher = Switcher(
            profileStore: store,
            slotStore: slotStore,
            desktopAuth: DesktopAuthService(resolver: resolver),
            resolver: resolver
        )

        // The switch must throw — NOT install B's stale tokens.
        await #expect(throws: (any Error).self) {
            _ = try await switcher.switchTo(
                incoming: profileB,
                outgoingActor: actorA,
                incomingActor: actorB
            )
        }

        // Live auth.json must still be A's tokens (untouched).
        let live = try Snapshotter.read(liveURL)
        #expect(live.tokens?.refreshToken == "rt-A", "Live auth.json should not have been overwritten with B's stale tokens")

        // Slot must still point to A.
        #expect(slotStore.loadActiveID() == profileA.id, "Slot should not have changed")
    }

    /// When incoming profile's tokens are still valid (not expired), the switch
    /// proceeds without hitting the refresh endpoint at all.
    @Test("Switch proceeds without refresh when incoming tokens are not expired")
    func switchProceedsWithValidTokens() async throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let liveURL = codexDir.appendingPathComponent("auth.json")

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: home.appendingPathComponent("active-slot.json"))

        // Both profiles have non-expired tokens. Access tokens must be valid
        // JWTs with future `exp` so `refreshIfNeeded()` skips the refresh.
        let futureExp = Date().addingTimeInterval(3600)
        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", exp: futureExp)
        let accessA = try Self.idToken(user: "user-A", account: "acct-A", exp: futureExp)
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: accessA, refreshToken: "rt-A", accountID: "acct-A"))
        let profileA = Profile(label: "A", dedupKey: "user-A::acct-A")
        try store.insert(profileA, snapshot: authA)

        let tokenB = try Self.idToken(user: "user-B", account: "acct-B", exp: futureExp)
        let accessB = try Self.idToken(user: "user-B", account: "acct-B", exp: futureExp)
        let authB = AuthJSON(tokens: AuthTokens(idToken: tokenB, accessToken: accessB, refreshToken: "rt-B", accountID: "acct-B"))
        let profileB = Profile(label: "B", dedupKey: "user-B::acct-B")
        try store.insert(profileB, snapshot: authB)

        try Snapshotter.write(authA, to: liveURL)
        try slotStore.setActiveID(profileA.id)

        let actorA = PerProfile(profileID: profileA.id, snapshotURL: store.snapshotURL(for: profileA.id))
        let actorB = PerProfile(profileID: profileB.id, snapshotURL: store.snapshotURL(for: profileB.id))

        let switcher = Switcher(
            profileStore: store,
            slotStore: slotStore,
            desktopAuth: DesktopAuthService(resolver: resolver),
            resolver: resolver
        )

        _ = try await switcher.switchTo(
            incoming: profileB,
            outgoingActor: actorA,
            incomingActor: actorB
        )

        let live = try Snapshotter.read(liveURL)
        #expect(live.tokens?.refreshToken == "rt-B")
        #expect(slotStore.loadActiveID() == profileB.id)
    }
}
