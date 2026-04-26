import Testing
import Foundation
@testable import CodexSwitcher

@Suite("PerProfile — actor", .serialized)
struct PerProfileTests {

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String = "u", account: String = "a", exp: Date) throws -> String {
        let payload: [String: Any] = [
            "exp": exp.timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_user_id": user,
                "chatgpt_account_id": account,
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    private static func tempSnapshot(_ exp: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perprofile-tests-\(UUID().uuidString)")
            .appendingPathComponent("auth.json")
        let token = try idToken(exp: exp)
        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: token, refreshToken: "rt", accountID: "a"))
        try Snapshotter.write(auth, to: url)
        return url
    }

    // MARK: - usage() coalescing & TTL

    @Test("Single-flight: concurrent usage() calls share one HTTP request")
    func singleFlightUsage() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        let session = MockURLProtocol.makeSession()
        let counter = AtomicCounter()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            // Slow path so concurrent callers all queue up
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "primary": ["used_percent": 1.0],
            ])
        }

        let actor = PerProfile(
            profileID: "p", snapshotURL: snapURL,
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session)
        )

        async let r1 = actor.usage()
        async let r2 = actor.usage()
        async let r3 = actor.usage()
        _ = try await (r1, r2, r3)

        #expect(counter.value == 1)
    }

    @Test("TTL: a second call within 15s reuses the cached response")
    func cacheTTL() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        let session = MockURLProtocol.makeSession()
        let counter = AtomicCounter()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            counter.increment()
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "primary": ["used_percent": 1.0],
            ])
        }

        let actor = PerProfile(
            profileID: "p", snapshotURL: snapURL,
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session)
        )

        _ = try await actor.usage()
        _ = try await actor.usage()
        _ = try await actor.usage()
        #expect(counter.value == 1)
    }

    @Test("writeSnapshot invalidates the usage cache")
    func writeInvalidatesCache() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        let session = MockURLProtocol.makeSession()
        let counter = AtomicCounter()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            counter.increment()
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "primary": ["used_percent": 1.0],
            ])
        }

        let actor = PerProfile(
            profileID: "p", snapshotURL: snapURL,
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session)
        )

        _ = try await actor.usage()
        // Rewrite snapshot — cache should drop.
        let auth = try await actor.readSnapshot()
        try await actor.writeSnapshot(auth)
        _ = try await actor.usage()
        #expect(counter.value == 2)
    }

    // MARK: - refreshIfNeeded

    @Test("Fresh access token: no refresh call")
    func freshTokenSkipsRefresh() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        let session = MockURLProtocol.makeSession()
        let counter = AtomicCounter()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            counter.increment()
            #expect(request.url != BackendConstants.tokenRefreshURL, "Refresh should not happen for a fresh token")
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [:])
        }

        let actor = PerProfile(
            profileID: "p", snapshotURL: snapURL,
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session)
        )
        _ = try await actor.refreshIfNeeded()
        #expect(counter.value == 0)
    }

    @Test("Expired access token: refresh runs, snapshot is rewritten with rotated tokens")
    func expiredTokenTriggersRefresh() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(-3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        let session = MockURLProtocol.makeSession()
        let newAccess = try Self.idToken(exp: Date().addingTimeInterval(3600))
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            #expect(request.url == BackendConstants.tokenRefreshURL)
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "access_token": newAccess,
                "refresh_token": "ROTATED",
                "id_token": newAccess,
                "token_type": "Bearer",
                "expires_in": 3600,
                "scope": "openid",
            ])
        }

        let actor = PerProfile(
            profileID: "p", snapshotURL: snapURL,
            backend: BackendClient(session: session),
            refresher: TokenRefresher(session: session)
        )
        let auth = try await actor.refreshIfNeeded()
        #expect(auth.tokens?.refreshToken == "ROTATED")

        // Persisted to disk so the *next* read sees the rotated token.
        let onDisk = try Snapshotter.read(snapURL)
        #expect(onDisk.tokens?.refreshToken == "ROTATED")
    }

    // MARK: - importUpdate freshness ordering

    @Test("importUpdate prefers incoming when its lastRefresh is newer")
    func importUpdatePrefersNewer() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        var existing = try Snapshotter.read(snapURL)
        existing.lastRefresh = Date(timeIntervalSince1970: 1000)
        try Snapshotter.write(existing, to: snapURL)

        let actor = PerProfile(profileID: "p", snapshotURL: snapURL)

        var incoming = existing
        incoming.tokens?.refreshToken = "newer-rt"
        incoming.lastRefresh = Date(timeIntervalSince1970: 2000)
        try await actor.importUpdate(with: incoming)

        let after = try await actor.readSnapshot()
        #expect(after.tokens?.refreshToken == "newer-rt")
    }

    @Test("importUpdate keeps existing when incoming is older")
    func importUpdateKeepsNewer() async throws {
        let snapURL = try Self.tempSnapshot(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: snapURL.deletingLastPathComponent()) }

        var existing = try Snapshotter.read(snapURL)
        existing.tokens?.refreshToken = "current"
        existing.lastRefresh = Date(timeIntervalSince1970: 2000)
        try Snapshotter.write(existing, to: snapURL)

        let actor = PerProfile(profileID: "p", snapshotURL: snapURL)

        var older = existing
        older.tokens?.refreshToken = "older"
        older.lastRefresh = Date(timeIntervalSince1970: 1000)
        try await actor.importUpdate(with: older)

        let after = try await actor.readSnapshot()
        #expect(after.tokens?.refreshToken == "current")
    }
}

/// Thread-safe counter used by URLProtocol handler closures, which run on
/// non-actor threads.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
