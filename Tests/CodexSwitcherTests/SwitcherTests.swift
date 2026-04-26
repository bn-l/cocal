import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Switcher — A→B swap")
struct SwitcherTests {

    // MARK: - Fixture helpers

    private static func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Build an id_token bearing the chatgpt_user_id / chatgpt_account_id claims so
    /// `Snapshotter.dedupKey` and the import path see what they need.
    private static func idToken(user: String, account: String, email: String? = nil, exp: Date? = nil) throws -> String {
        var inner: [String: Any] = [
            "chatgpt_user_id": user,
            "chatgpt_account_id": account,
        ]
        var payload: [String: Any] = [
            "https://api.openai.com/auth": inner,
        ]
        if let email { payload["email"] = email }
        if let exp { payload["exp"] = exp.timeIntervalSince1970 }
        _ = inner
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    private static func makeAuth(user: String, account: String, refreshToken: String, lastRefresh: Date? = nil) throws -> AuthJSON {
        let token = try idToken(user: user, account: account)
        return AuthJSON(
            tokens: AuthTokens(idToken: token, accessToken: "ax-\(refreshToken)", refreshToken: refreshToken, accountID: account),
            lastRefresh: lastRefresh
        )
    }

    /// Create two profiles in the store — A (active) and B (incoming) — with
    /// independent dedup keys and snapshot files.
    private struct Fixture {
        let home: URL
        let liveURL: URL
        let store: ProfileStore
        let slotStore: SlotStore
        let switcher: Switcher
        let resolver: AuthPathResolver
        let profileA: Profile
        let profileB: Profile
        let actorA: PerProfile
        let actorB: PerProfile
    }

    private static func makeFixture() throws -> Fixture {
        let home = tempHome()
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let liveURL = codexDir.appendingPathComponent("auth.json")

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)

        let storeRoot = home.appendingPathComponent("profiles")
        let store = ProfileStore(rootDirectory: storeRoot)
        let slotURL = home.appendingPathComponent("active-slot.json")
        let slotStore = SlotStore(url: slotURL)

        let authA = try makeAuth(user: "user-A", account: "acct-A", refreshToken: "rA")
        let authB = try makeAuth(user: "user-B", account: "acct-B", refreshToken: "rB")
        let profileA = Profile(label: "A", dedupKey: "user-A::acct-A")
        let profileB = Profile(label: "B", dedupKey: "user-B::acct-B")
        try store.insert(profileA, snapshot: authA)
        try store.insert(profileB, snapshot: authB)

        // Live auth currently belongs to profile A — that's what "active" means
        // before the swap. Use a *different* refresh token than the one in A's
        // stored snapshot so we can prove capture-live overwrites it.
        let liveAuthA = try makeAuth(user: "user-A", account: "acct-A", refreshToken: "rA-FRESH", lastRefresh: Date())
        try Snapshotter.write(liveAuthA, to: liveURL)

        let desktopAuth = DesktopAuthService(resolver: resolver, keychainEnabled: false)
        let switcher = Switcher(profileStore: store, slotStore: slotStore, desktopAuth: desktopAuth, resolver: resolver)

        let actorA = PerProfile(profileID: profileA.id, snapshotURL: store.snapshotURL(for: profileA.id))
        let actorB = PerProfile(profileID: profileB.id, snapshotURL: store.snapshotURL(for: profileB.id))

        return Fixture(
            home: home,
            liveURL: liveURL,
            store: store,
            slotStore: slotStore,
            switcher: switcher,
            resolver: resolver,
            profileA: profileA,
            profileB: profileB,
            actorA: actorA,
            actorB: actorB
        )
    }

    // MARK: - Tests

    @Test("Swap installs B's auth at the canonical path")
    func liveAuthIsBAfterSwap() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        _ = try await f.switcher.switchTo(
            incoming: f.profileB,
            outgoingActor: f.actorA,
            incomingActor: f.actorB
        )

        let live = try Snapshotter.read(f.liveURL)
        #expect(live.tokens?.refreshToken == "rB")
        #expect(live.tokens?.accountID == "acct-B")
    }

    @Test("Capture-live: A's stored snapshot picks up the live refresh token before swap")
    func capturesActiveProfilesFreshness() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        // Pre-condition: A's stored snapshot has the stale token, live has the fresh one.
        let preA = try Snapshotter.read(f.store.snapshotURL(for: f.profileA.id))
        #expect(preA.tokens?.refreshToken == "rA")

        _ = try await f.switcher.switchTo(
            incoming: f.profileB,
            outgoingActor: f.actorA,
            incomingActor: f.actorB
        )

        let postA = try Snapshotter.read(f.store.snapshotURL(for: f.profileA.id))
        #expect(postA.tokens?.refreshToken == "rA-FRESH")
    }

    @Test("Slot pointer flips to incoming after swap")
    func slotPointerUpdated() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        _ = try await f.switcher.switchTo(
            incoming: f.profileB,
            outgoingActor: f.actorA,
            incomingActor: f.actorB
        )
        #expect(f.slotStore.loadActiveID() == f.profileB.id)
    }

    @Test("Live auth.json gets mode 0600")
    func liveFileIsMode0600() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        _ = try await f.switcher.switchTo(
            incoming: f.profileB,
            outgoingActor: f.actorA,
            incomingActor: f.actorB
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: f.liveURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test("Backup .bak is created from the previous live file")
    func backupCreatedFromPriorLive() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        _ = try await f.switcher.switchTo(
            incoming: f.profileB,
            outgoingActor: f.actorA,
            incomingActor: f.actorB
        )
        let backup = f.liveURL.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let prior = try Snapshotter.read(backup)
        #expect(prior.tokens?.refreshToken == "rA-FRESH")  // backup of the *previous* live file
    }

    @Test("First-time swap (no outgoing actor) installs and sets slot")
    func firstTimeSwapNoOutgoing() async throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)

        let resolver = AuthPathResolver(environment: [:], homeDirectory: home)
        let store = ProfileStore(rootDirectory: home.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: home.appendingPathComponent("active-slot.json"))
        let auth = try Self.makeAuth(user: "u", account: "a", refreshToken: "r")
        let profile = Profile(label: "Solo", dedupKey: "u::a")
        try store.insert(profile, snapshot: auth)
        let actor = PerProfile(profileID: profile.id, snapshotURL: store.snapshotURL(for: profile.id))

        let switcher = Switcher(
            profileStore: store,
            slotStore: slotStore,
            desktopAuth: DesktopAuthService(resolver: resolver, keychainEnabled: false),
            resolver: resolver
        )

        let target = try await switcher.switchTo(incoming: profile, outgoingActor: nil, incomingActor: actor)
        #expect(target.path == home.appendingPathComponent(".codex/auth.json").path)
        #expect(slotStore.loadActiveID() == profile.id)
    }

    @Test("Switching to the same actor instance throws .sameProfile")
    func sameProfileError() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.home) }

        await #expect(throws: Switcher.SwitchError.self) {
            _ = try await f.switcher.switchTo(
                incoming: f.profileA,
                outgoingActor: f.actorA,
                incomingActor: f.actorA
            )
        }
    }
}
