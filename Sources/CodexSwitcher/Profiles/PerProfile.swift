import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "PerProfile")

public struct ProfileSnapshotIdentityError: Error, Equatable, LocalizedError, Sendable {
    public let profileID: String
    public let expectedDedupKey: String
    public let actualDedupKey: String

    public var errorDescription: String? {
        "Stored credentials do not belong to this imported profile."
    }
}

/// The single ownership boundary for any read-modify-write on a profile snapshot
/// (PLAN.md §2.3 "Per-profile write serialization"). Concurrent calls on the same
/// `PerProfile` actor serialize automatically; cross-profile flows acquire actors
/// in the order **outgoing → incoming** to avoid deadlock.
///
/// Three previously-separate concerns collapse into one boundary:
///   1. Snapshot-write serialization (single-use refresh-token rotation safety).
///   2. In-flight HTTPS coalescing (single-flight per profile).
///   3. SnapshotCache (15s TTL on the most recent successful poll).
public actor PerProfile {
    public let profileID: String

    /// Where the on-disk `auth.json` snapshot lives. Owned exclusively by this actor.
    public let snapshotURL: URL
    private let expectedDedupKey: String?

    private let backend: BackendClient
    private let refresher: TokenRefresher
    private let now: @Sendable () -> Date

    /// 15-second TTL cache (PLAN.md §2.3 OfficialSnapshotCache).
    private var cachedUsage: (response: UsageResponse, at: Date)?
    private var cachedAccount: (response: AccountsCheckResponse, at: Date)?

    /// Single-flight per call kind. While one fetch is in flight, additional calls
    /// `await` the same `Task` instead of issuing a duplicate request (PLAN.md §2.3
    /// OfficialFetchGate).
    private var inflightUsage: Task<UsageResponse, Swift.Error>?
    private var inflightAccount: Task<AccountsCheckResponse, Swift.Error>?

    public static let cacheTTL: TimeInterval = 15

    public init(
        profileID: String,
        snapshotURL: URL,
        expectedDedupKey: String? = nil,
        backend: BackendClient = BackendClient(),
        refresher: TokenRefresher = TokenRefresher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profileID = profileID
        self.snapshotURL = snapshotURL
        self.expectedDedupKey = expectedDedupKey
        self.backend = backend
        self.refresher = refresher
        self.now = now
    }

    // MARK: - Snapshot I/O

    public func readSnapshot() throws -> AuthJSON {
        let auth = try Snapshotter.read(snapshotURL)
        try validateSnapshotIdentity(auth)
        return auth
    }

    public func writeSnapshot(_ auth: AuthJSON) throws {
        try validateSnapshotIdentity(auth)
        try Snapshotter.write(auth, to: snapshotURL)
        // Any cached HTTPS data was tied to the prior tokens — drop it.
        cachedUsage = nil
        cachedAccount = nil
    }

    private func validateSnapshotIdentity(_ auth: AuthJSON) throws {
        guard let expectedDedupKey else { return }
        let actualDedupKey = try Snapshotter.dedupKey(for: auth)
        guard actualDedupKey == expectedDedupKey else {
            throw ProfileSnapshotIdentityError(
                profileID: profileID,
                expectedDedupKey: expectedDedupKey,
                actualDedupKey: actualDedupKey
            )
        }
    }

    /// Replace the snapshot with the contents currently sitting at the live Codex
    /// auth path. PLAN.md §2.3 step 1 of the swap: capture the active profile's
    /// freshness *before* installing a new one.
    public func captureLive(from liveURL: URL) throws {
        let live = try Snapshotter.read(liveURL)
        try writeSnapshot(live)
    }

    /// Import-update path: an Import flow re-saw an already-known profile with
    /// (possibly) fresher tokens than what we have stored. Take the newer one.
    /// "Newer" is decided by `last_refresh` if present, falling back to access-token
    /// `exp` claim — the larger value wins.
    public func importUpdate(with incoming: AuthJSON) throws {
        let existing = try? Snapshotter.read(snapshotURL)
        if shouldPrefer(incoming, over: existing) {
            try writeSnapshot(incoming)
        }
    }

    private func shouldPrefer(_ incoming: AuthJSON, over existing: AuthJSON?) -> Bool {
        guard let existing else { return true }
        switch (incoming.freshnessMarker, existing.freshnessMarker) {
        case let (i?, e?): return i > e
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return true
        }
    }

    // MARK: - Refresh

    /// If the access token is expired or near-expiry, hit the OAuth endpoint and
    /// persist the rotated tokens immediately. Returns the (possibly new) snapshot.
    @discardableResult
    public func refreshIfNeeded() async throws -> AuthJSON {
        let auth = try readSnapshot()
        guard let tokens = auth.tokens else { throw Snapshotter.Error.missingTokens }
        let claims = (try? JWT.decode(tokens.accessToken)) ?? JWT.Claims(
            exp: nil, email: nil, chatgptUserID: nil, chatgptAccountID: nil, chatgptPlanType: nil
        )
        guard JWT.isExpired(claims, now: now()) else { return auth }

        return try await refresh(auth: auth, tokens: tokens)
    }

    private func forceRefresh() async throws -> AuthJSON {
        let auth = try readSnapshot()
        guard let tokens = auth.tokens else { throw Snapshotter.Error.missingTokens }
        return try await refresh(auth: auth, tokens: tokens)
    }

    private func refresh(auth original: AuthJSON, tokens: AuthTokens) async throws -> AuthJSON {
        var auth = original
        logger.info("Refreshing token for profile=\(self.profileID, privacy: .public)")
        flog("PerProfile", "Refreshing token for profile=\(profileID)")
        let response = try await refresher.refresh(refreshToken: tokens.refreshToken)
        auth.tokens = AuthTokens(
            idToken: response.idToken ?? tokens.idToken,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            accountID: tokens.accountID
        )
        auth.lastRefresh = now()
        try writeSnapshot(auth)
        return auth
    }

    // MARK: - HTTPS coalescing

    nonisolated private func accountID(for tokens: AuthTokens) -> String {
        tokens.accountID ?? (try? JWT.decode(tokens.idToken).chatgptAccountID) ?? ""
    }

    /// Single-flight + 15s-TTL wrapper around `BackendClient.usage`.
    public func usage() async throws -> UsageResponse {
        if let cached = cachedUsage, now().timeIntervalSince(cached.at) < Self.cacheTTL {
            return cached.response
        }
        if let inflight = inflightUsage {
            return try await inflight.value
        }
        let task = Task<UsageResponse, Swift.Error> { [backend] in
            let auth = try await self.refreshIfNeeded()
            guard let tokens = auth.tokens else { throw Snapshotter.Error.missingTokens }
            do {
                return try await backend.usage(accessToken: tokens.accessToken, accountID: self.accountID(for: tokens))
            } catch let BackendError.http(status, _) where status == 401 {
                logger.warning("Usage endpoint rejected access token for profile=\(self.profileID, privacy: .public); forcing one refresh and retry")
                flog("PerProfile", "Usage 401 for profile=\(self.profileID); forcing refresh and retry")
                let refreshed = try await self.forceRefresh()
                guard let refreshedTokens = refreshed.tokens else { throw Snapshotter.Error.missingTokens }
                return try await backend.usage(
                    accessToken: refreshedTokens.accessToken,
                    accountID: self.accountID(for: refreshedTokens)
                )
            }
        }
        inflightUsage = task
        defer { inflightUsage = nil }
        let result = try await task.value
        cachedUsage = (result, now())
        return result
    }

    /// Single-flight + 15s-TTL wrapper around `BackendClient.accountsCheck`.
    public func accountsCheck() async throws -> AccountsCheckResponse {
        if let cached = cachedAccount, now().timeIntervalSince(cached.at) < Self.cacheTTL {
            return cached.response
        }
        if let inflight = inflightAccount {
            return try await inflight.value
        }
        let task = Task<AccountsCheckResponse, Swift.Error> { [backend] in
            let auth = try await self.refreshIfNeeded()
            guard let tokens = auth.tokens else { throw Snapshotter.Error.missingTokens }
            do {
                return try await backend.accountsCheck(accessToken: tokens.accessToken, accountID: self.accountID(for: tokens))
            } catch let BackendError.http(status, _) where status == 401 {
                logger.warning("Accounts endpoint rejected access token for profile=\(self.profileID, privacy: .public); forcing one refresh and retry")
                flog("PerProfile", "Accounts 401 for profile=\(self.profileID); forcing refresh and retry")
                let refreshed = try await self.forceRefresh()
                guard let refreshedTokens = refreshed.tokens else { throw Snapshotter.Error.missingTokens }
                return try await backend.accountsCheck(
                    accessToken: refreshedTokens.accessToken,
                    accountID: self.accountID(for: refreshedTokens)
                )
            }
        }
        inflightAccount = task
        defer { inflightAccount = nil }
        let result = try await task.value
        cachedAccount = (result, now())
        return result
    }
}
