import Testing
import Foundation
@testable import CodexSwitcher

/// Regression: user logged out of profile A in Codex, logged into profile B via
/// `codex login`, then restarted the app. The live `auth.json` contained B's
/// credentials but the slot store still pointed to A. The app polled with A's
/// (now-invalid) tokens → HTTP 401 → "Unable to fetch usage data", and the
/// profile list showed A as selected despite B being the actual live account.
///
/// Root cause: `activeID` was only updated during explicit Import or Switch flows.
/// Nothing reconciled the slot against the live `auth.json` on startup or poll.
///
/// The fix: on every poll cycle, read the live `auth.json`, extract its dedup key,
/// and if it doesn't match the current active profile, update the slot.
@Suite("Active slot reconciliation with live auth.json", .serialized)
@MainActor
struct ActiveSlotReconciliationTests {

    // MARK: - Helpers

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-reconcile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String, email: String, plan: String = "plus") throws -> String {
        let inner: [String: Any] = [
            "chatgpt_user_id": user,
            "chatgpt_account_id": account,
            "chatgpt_plan_type": plan,
        ]
        let payload: [String: Any] = [
            "https://api.openai.com/auth": inner,
            "email": email,
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    // MARK: - Tests

    /// The exact scenario from the bug report: slot says profile A is active,
    /// but the live auth.json on disk belongs to profile B. After reloadProfiles(),
    /// `activeID` must reflect B — the live credentials are the source of truth.
    @Test("Slot reconciles to match live auth.json when dedup key differs from active profile")
    func reconcilesStaleSlotonReload() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))

        // Profile A — litwin.catherine equivalent
        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", email: "a@example.com")
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: "at-a", refreshToken: "rt-a", accountID: "acct-A"))
        let profileA = Profile(id: "id-A", label: "a@example.com", dedupKey: "user-A::acct-A", planType: "plus")
        try store.insert(profileA, snapshot: authA)

        // Profile B — keytrex equivalent
        let tokenB = try Self.idToken(user: "user-B", account: "acct-B", email: "b@example.com")
        let authB = AuthJSON(tokens: AuthTokens(idToken: tokenB, accessToken: "at-b", refreshToken: "rt-b", accountID: "acct-B"))
        let profileB = Profile(id: "id-B", label: "b@example.com", dedupKey: "user-B::acct-B", planType: "plus")
        try store.insert(profileB, snapshot: authB)

        // Slot says A is active…
        try slot.setActiveID(profileA.id)

        // …but the live auth.json on disk has B's credentials (user ran `codex login` with B).
        let homeDir = dir.appendingPathComponent("home")
        let liveAuthURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Snapshotter.write(authB, to: liveAuthURL)

        let resolver = AuthPathResolver(environment: [:], homeDirectory: homeDir)
        let env = AppEnvironment(profileStore: store, slotStore: slot, resolver: resolver)

        let monitor = UsageMonitor()
        monitor.environment = env

        // Simulate app startup: reloadProfiles is called in CodexSwitcherApp.init
        // and at the top of every poll(). After this, activeID must reflect B.
        monitor.reloadProfiles()

        #expect(
            monitor.activeID == profileB.id,
            "activeID should reconcile to profile B (the live auth.json owner), not remain on profile A. Got activeID=\(monitor.activeID ?? "nil")"
        )
    }

    /// When the live auth.json matches the current active profile, no change needed.
    @Test("No reconciliation when live auth.json already matches active profile")
    func noChangeWhenAlreadyInSync() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))

        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", email: "a@example.com")
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: "at-a", refreshToken: "rt-a", accountID: "acct-A"))
        let profileA = Profile(id: "id-A", label: "a@example.com", dedupKey: "user-A::acct-A")
        try store.insert(profileA, snapshot: authA)

        try slot.setActiveID(profileA.id)

        // Live auth.json also has A's credentials — in sync.
        let homeDir = dir.appendingPathComponent("home")
        let liveAuthURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Snapshotter.write(authA, to: liveAuthURL)

        let resolver = AuthPathResolver(environment: [:], homeDirectory: homeDir)
        let env = AppEnvironment(profileStore: store, slotStore: slot, resolver: resolver)

        let monitor = UsageMonitor()
        monitor.environment = env
        monitor.reloadProfiles()

        #expect(monitor.activeID == profileA.id)
    }

    /// When the live auth.json doesn't match ANY imported profile, activeID
    /// should remain unchanged (the user hasn't imported the new account yet).
    @Test("No reconciliation when live auth.json matches no imported profile")
    func noChangeWhenLiveAuthUnrecognised() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))

        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", email: "a@example.com")
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: "at-a", refreshToken: "rt-a", accountID: "acct-A"))
        let profileA = Profile(id: "id-A", label: "a@example.com", dedupKey: "user-A::acct-A")
        try store.insert(profileA, snapshot: authA)
        try slot.setActiveID(profileA.id)

        // Live auth.json has credentials for an UNKNOWN account (not imported yet).
        let tokenX = try Self.idToken(user: "user-X", account: "acct-X", email: "x@example.com")
        let authX = AuthJSON(tokens: AuthTokens(idToken: tokenX, accessToken: "at-x", refreshToken: "rt-x", accountID: "acct-X"))
        let homeDir = dir.appendingPathComponent("home")
        let liveAuthURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Snapshotter.write(authX, to: liveAuthURL)

        let resolver = AuthPathResolver(environment: [:], homeDirectory: homeDir)
        let env = AppEnvironment(profileStore: store, slotStore: slot, resolver: resolver)

        let monitor = UsageMonitor()
        monitor.environment = env
        monitor.reloadProfiles()

        #expect(monitor.activeID == profileA.id, "Should not change active profile when live auth matches no imported profile")
    }

    /// When no live auth.json exists at all, activeID stays as-is.
    @Test("No reconciliation when live auth.json is absent")
    func noChangeWhenNoLiveAuth() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))

        let tokenA = try Self.idToken(user: "user-A", account: "acct-A", email: "a@example.com")
        let authA = AuthJSON(tokens: AuthTokens(idToken: tokenA, accessToken: "at-a", refreshToken: "rt-a", accountID: "acct-A"))
        let profileA = Profile(id: "id-A", label: "a@example.com", dedupKey: "user-A::acct-A")
        try store.insert(profileA, snapshot: authA)
        try slot.setActiveID(profileA.id)

        // No live auth.json on disk — homeDir/.codex/auth.json doesn't exist.
        let homeDir = dir.appendingPathComponent("home-empty")

        let resolver = AuthPathResolver(environment: [:], homeDirectory: homeDir)
        let env = AppEnvironment(profileStore: store, slotStore: slot, resolver: resolver)

        let monitor = UsageMonitor()
        monitor.environment = env
        monitor.reloadProfiles()

        #expect(monitor.activeID == profileA.id)
    }
}
