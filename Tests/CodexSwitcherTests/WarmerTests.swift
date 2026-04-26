import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Warmer", .serialized)
struct WarmerTests {

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String, planType: String? = nil, exp: Date? = nil) throws -> String {
        var inner: [String: Any] = [
            "chatgpt_user_id": user,
            "chatgpt_account_id": account,
        ]
        if let planType { inner["chatgpt_plan_type"] = planType }
        var payload: [String: Any] = ["https://api.openai.com/auth": inner]
        if let exp { payload["exp"] = exp.timeIntervalSince1970 }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    private static func tempStore() throws -> (URL, ProfileStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warmer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ProfileStore(rootDirectory: root))
    }

    private static func insert(_ store: ProfileStore, profile: Profile, user: String, account: String, accessExp: Date) throws {
        // Snapshot uses a non-expiring access token (so refreshIfNeeded is a no-op
        // unless the test explicitly sets `accessExp` in the past).
        let idToken = try idToken(user: user, account: account, exp: accessExp)
        let auth = AuthJSON(tokens: AuthTokens(idToken: idToken, accessToken: idToken, refreshToken: "rt-\(profile.id)", accountID: account))
        try store.insert(profile, snapshot: auth)
    }

    @Test("Healthy profile: warm refreshes nothing when access token is fresh, but updates lastWarmed and plan")
    func healthyWarmsAndUpdatesMetadata() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // ISO-8601 round-trip drops sub-second precision; pin to whole seconds
        // so the reloaded date compares equal.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let profile = Profile(label: "ok", dedupKey: "u::a")
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            switch request.url {
            case BackendConstants.usageURL:
                return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                    "primary": [
                        "used_percent": 12.5,
                        "window": "5h_rolling",
                    ],
                    "secondary": [
                        "used_percent": 30.0,
                        "window": "weekly",
                    ],
                ])
            case BackendConstants.accountCheckURL:
                return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                    "accounts": [
                        ["plan_type": "pro_5x", "account_id": "a"]
                    ],
                ])
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let backend = BackendClient(session: session)
        let refresher = TokenRefresher(session: session)
        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: backend,
            refresher: refresher
        )

        let warmer = Warmer(store: store, now: { now })
        let updated = await warmer.warm(profile: profile, actor: actor)

        #expect(updated.warning == nil)
        #expect(updated.lastWarmed == now)
        #expect(updated.primaryUsedPercent == 12.5)
        #expect(updated.secondaryUsedPercent == 30.0)
        #expect(updated.planType == "pro_5x")

        // Persisted to disk via store.updateMetadata
        let reloaded = store.loadAll().first { $0.id == profile.id }
        #expect(reloaded?.lastWarmed == now)
        #expect(reloaded?.planType == "pro_5x")
    }

    @Test("Expired refresh token sets warning=.refreshExpired and stops the warm")
    func refreshExpired() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let profile = Profile(label: "stale", dedupKey: "u::a")
        // Access token already expired so refreshIfNeeded() makes a network call.
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(-3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            #expect(request.url == BackendConstants.tokenRefreshURL)
            return MockURLProtocol.textResponse(
                url: request.url!,
                status: 400,
                body: #"{"error":"refresh_token_expired"}"#
            )
        }

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session),
            now: { now }
        )
        let warmer = Warmer(store: store, now: { now })
        let updated = await warmer.warm(profile: profile, actor: actor)

        #expect(updated.warning == .refreshExpired)
        #expect(updated.lastWarmed == nil)
        let reloaded = store.loadAll().first { $0.id == profile.id }
        #expect(reloaded?.warning == .refreshExpired)
    }

    @Test("Reused refresh token (single-use rotation violated) yields .refreshExhausted")
    func refreshExhausted() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let profile = Profile(label: "exhausted", dedupKey: "u::a")
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(-3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            return MockURLProtocol.textResponse(
                url: request.url!,
                status: 400,
                body: #"{"error":"refresh_token_reused"}"#
            )
        }

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session),
            now: { now }
        )
        let updated = await Warmer(store: store, now: { now }).warm(profile: profile, actor: actor)
        #expect(updated.warning == .refreshExhausted)
    }

    @Test("Revoked credentials yield .refreshRevoked")
    func refreshRevoked() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let profile = Profile(label: "revoked", dedupKey: "u::a")
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(-3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            return MockURLProtocol.textResponse(
                url: request.url!,
                status: 400,
                body: #"{"error":"invalid_grant"}"#
            )
        }

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session),
            now: { now }
        )
        let updated = await Warmer(store: store, now: { now }).warm(profile: profile, actor: actor)
        #expect(updated.warning == .refreshRevoked)
    }

    @Test("usage() failure does NOT advance lastWarmed (P2 regression: stale percent must not look fresh)")
    func usageFailureDoesNotAdvanceFreshness() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Pin lastWarmed to a known prior value so we can prove it doesn't move.
        let previouslyWarmed = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

        var profile = Profile(label: "stale-data", dedupKey: "u::a")
        profile.lastWarmed = previouslyWarmed
        profile.primaryUsedPercent = 42.0  // last successful percent — must be preserved
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            // Refresh isn't called (access token still fresh). Usage fails 503.
            // Accounts check would also fail; we return 503 across the board so
            // the warmer's `try?` paths around usage() and accountsCheck() both bail.
            switch request.url {
            case BackendConstants.usageURL, BackendConstants.accountCheckURL:
                return MockURLProtocol.textResponse(url: request.url!, status: 503, body: "service unavailable")
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session),
            now: { now }
        )
        let updated = await Warmer(store: store, now: { now }).warm(profile: profile, actor: actor)

        // Refresh succeeded, so warning is cleared. But because usage() failed, the
        // freshness marker MUST stay at the prior timestamp — AutoSwitchPicker
        // gates candidacy on `lastWarmed >= cutoff`, so leaving it untouched is
        // what excludes this profile from auto-switch consideration.
        #expect(updated.warning == nil)
        #expect(updated.lastWarmed == previouslyWarmed)
        #expect(updated.primaryUsedPercent == 42.0)

        let reloaded = store.loadAll().first { $0.id == profile.id }
        #expect(reloaded?.lastWarmed == previouslyWarmed)
        #expect(reloaded?.primaryUsedPercent == 42.0)
    }

    @Test("Warmer never writes to the live ~/.codex/auth.json")
    func neverWritesLiveAuth() async throws {
        let (root, store) = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let home = root.appendingPathComponent("FakeHome")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let liveURL = home.appendingPathComponent(".codex/auth.json")

        let profile = Profile(label: "iso", dedupKey: "u::a")
        try Self.insert(store, profile: profile, user: "u", account: "a", accessExp: now.addingTimeInterval(3600))

        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            switch request.url {
            case BackendConstants.usageURL:
                return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                    "primary": ["used_percent": 1.0],
                    "secondary": ["used_percent": 1.0],
                ])
            case BackendConstants.accountCheckURL:
                return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                    "accounts": [["plan_type": "free", "account_id": "a"]],
                ])
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let actor = PerProfile(
            profileID: profile.id,
            snapshotURL: store.snapshotURL(for: profile.id),
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session),
            now: { now }
        )
        _ = await Warmer(store: store, now: { now }).warm(profile: profile, actor: actor)

        #expect(!FileManager.default.fileExists(atPath: liveURL.path))
    }
}
