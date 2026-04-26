import Testing
import Foundation
@testable import CodexSwitcher

@Suite("AppEnvironment.activeProfileAndActor")
struct AppEnvironmentTests {

    private static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appenv-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String) throws -> String {
        let inner: [String: Any] = ["chatgpt_user_id": user, "chatgpt_account_id": account]
        let payload: [String: Any] = ["https://api.openai.com/auth": inner]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    private static func insert(_ store: ProfileStore, label: String, dedupKey: String) throws -> Profile {
        let parts = dedupKey.components(separatedBy: "::")
        let token = try idToken(user: parts.first ?? "u", account: parts.last ?? "a")
        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: token, refreshToken: "rt", accountID: parts.last))
        let profile = Profile(label: label, dedupKey: dedupKey)
        try store.insert(profile, snapshot: auth)
        return profile
    }

    @Test("Returns the matching profile when activeID is set and present")
    func returnsActiveWhenPresent() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let a = try Self.insert(store, label: "Alpha", dedupKey: "ua::aa")
        _ = try Self.insert(store, label: "Bravo", dedupKey: "ub::ab")

        try slotStore.setActiveID(a.id)

        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        let pair = env.activeProfileAndActor()
        #expect(pair?.0.id == a.id)
    }

    @Test("Falls back to first-by-label when activeID is nil (initial first-import flow is safe)")
    func fallsBackWhenSlotIsNil() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let alpha = try Self.insert(store, label: "Alpha", dedupKey: "ua::aa")
        _ = try Self.insert(store, label: "Bravo", dedupKey: "ub::ab")

        // Slot is unset — first import has just happened, no profile has ever been "active".
        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        let pair = env.activeProfileAndActor()
        #expect(pair?.0.id == alpha.id)
    }

    @Test("Returns nil when activeID is set but the profile no longer exists (P1 regression)")
    func returnsNilOnDanglingActiveID() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        _ = try Self.insert(store, label: "Alpha", dedupKey: "ua::aa")
        _ = try Self.insert(store, label: "Bravo", dedupKey: "ub::ab")

        // Active slot points to an ID that no profile in the store carries —
        // exactly the state that arises if the active profile was deleted but
        // the slot pointer wasn't (or couldn't be) cleared.
        try slotStore.setActiveID("ghost-profile-id-that-does-not-exist")

        // Pre-fix behavior: this would silently fall back to the first profile
        // by label, and a subsequent switch would capture the live auth.json
        // (which still belongs to the deleted account) into the wrong slot.
        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        let pair = env.activeProfileAndActor()
        #expect(pair == nil)
    }

    @Test("Returns nil when no profiles exist at all")
    func returnsNilWhenStoreIsEmpty() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        #expect(env.activeProfileAndActor() == nil)
    }

    @Test("perProfile cache: same profile id returns the same actor instance across calls")
    func perProfileCacheIsStable() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let p = try Self.insert(store, label: "Alpha", dedupKey: "u::a")

        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        let a1 = env.perProfile(for: p)
        let a2 = env.perProfile(for: p)
        // Single-flight + single-use refresh-token rotation safety relies on this.
        // Two distinct PerProfile instances would each issue their own refresh
        // and one of them would reuse the rotated token.
        #expect(a1 === a2)
    }

    @Test("perProfile cache: different profiles → different actor instances")
    func perProfileDifferentProfilesDifferentActors() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let p1 = try Self.insert(store, label: "Alpha", dedupKey: "ua::aa")
        let p2 = try Self.insert(store, label: "Bravo", dedupKey: "ub::ab")

        let env = AppEnvironment(profileStore: store, slotStore: slotStore)
        #expect(env.perProfile(for: p1) !== env.perProfile(for: p2))
    }

    @Test("makeImporter wires the importer to the env's resolver and store")
    func makeImporterWiring() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDir = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let liveURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = try Self.idToken(user: "uX", account: "aX")
        let auth = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: token, refreshToken: "r", accountID: "aX"))
        try Snapshotter.write(auth, to: liveURL)

        let store = ProfileStore(rootDirectory: root.appendingPathComponent("profiles"))
        let slotStore = SlotStore(url: root.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(
            profileStore: store,
            slotStore: slotStore,
            resolver: AuthPathResolver(environment: [:], homeDirectory: homeDir)
        )

        let importer = env.makeImporter()
        let (outcome, _) = try importer.runImport()
        guard case .imported = outcome else {
            #expect(Bool(false), "expected .imported, got \(outcome)"); return
        }
        // Profile landed in the env's store.
        #expect(store.loadByDedupKey("uX::aX") != nil)
    }
}
