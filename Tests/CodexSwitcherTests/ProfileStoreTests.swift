import Testing
import Foundation
@testable import CodexSwitcher

@Suite("ProfileStore + SlotStore")
struct ProfileStoreTests {

    private static func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sampleAuth() -> AuthJSON {
        AuthJSON(
            tokens: AuthTokens(idToken: "i.j.k", accessToken: "a", refreshToken: "r", accountID: "acct")
        )
    }

    @Test("insert + loadAll round-trip with metadata persistence")
    func insertRoundtrip() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root)
        let profile = Profile(label: "work@example.com", dedupKey: "user-1::acct-1", planType: "pro_5x")
        try store.insert(profile, snapshot: Self.sampleAuth())

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.dedupKey == "user-1::acct-1")
        #expect(FileManager.default.fileExists(atPath: store.snapshotURL(for: profile.id).path))
    }

    @Test("loadByDedupKey finds the matching profile (the import flow's dedup check)")
    func dedupLookup() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root)
        let p = Profile(label: "a", dedupKey: "user-1::acct-1")
        try store.insert(p, snapshot: Self.sampleAuth())

        #expect(store.loadByDedupKey("user-1::acct-1")?.id == p.id)
        #expect(store.loadByDedupKey("user-2::acct-2") == nil)
    }

    @Test("remove deletes the entire profile directory")
    func removeProfile() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(rootDirectory: root)
        let p = Profile(label: "a", dedupKey: "user-1::acct-1")
        try store.insert(p, snapshot: Self.sampleAuth())

        try store.remove(p.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: p.id).path))
        #expect(store.loadAll().isEmpty)
    }

    @Test("SlotStore persists and reads back the active profile id")
    func slotStoreRoundtrip() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let slot = SlotStore(url: root.appendingPathComponent("slot.json"))
        #expect(slot.loadActiveID() == nil)
        try slot.setActiveID("profile-123")
        #expect(slot.loadActiveID() == "profile-123")
        try slot.setActiveID(nil)
        #expect(slot.loadActiveID() == nil)
    }
}
