import Testing
import SwiftUI
import Foundation
@testable import CodexSwitcher

/// Issue (red-green round 2): the previous fix sync-loaded profiles inside
/// `ProfileListView.init` via `@State(initialValue:)`. That works on first
/// mount but not in production — `MenuBarExtra(.window)` keeps the SwiftUI
/// view tree alive between popover opens, so `@State` is captured at first
/// init and stays stale even when the underlying store changes. The user
/// could import a credential, watch `.refreshed` come back, and still see
/// the empty Import-credentials state because the view's `@State profiles`
/// was locked in at `[]` from a render that pre-dated the import.
///
/// Fix: surface the profile list on `UsageMonitor` itself (which is
/// `@Observable`) so every render reflects current state without local
/// `@State` stickiness. `ProfileListView` then reads `monitor.profiles` and
/// `monitor.activeID` directly. Each `poll()` and explicit
/// `reloadProfiles()` refresh those values, and the @Observable framework
/// re-renders any view that read them.
///
/// These tests exercise real `ProfileStore`, real `SlotStore`, real
/// `UsageMonitor` — no mocks, no fakes.
@Suite("UsageMonitor — observable profile list", .serialized)
@MainActor
struct MonitorProfilesObservableTests {

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-monitor-profiles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("monitor.reloadProfiles() pulls the on-disk store into observable state")
    func reloadProfilesPopulatesObservableList() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let snap = AuthJSON(tokens: AuthTokens(idToken: "h.eyJlbWFpbCI6InRlc3RAeC5jb20ifQ.s", accessToken: "a", refreshToken: "r", accountID: "a1"))
        let profile = Profile(id: "p-obs", label: "obs@example.com", dedupKey: "u::a1", planType: "plus")
        try store.insert(profile, snapshot: snap)
        try slot.setActiveID(profile.id)

        let env = AppEnvironment(profileStore: store, slotStore: slot)
        let monitor = makeTestMonitor()
        monitor.environment = env

        // Pre-fix: `monitor.profiles` doesn't exist on UsageMonitor at all.
        // Post-fix: it's an observable property; reloadProfiles drives it.
        monitor.reloadProfiles()
        #expect(monitor.profiles.count == 1)
        #expect(monitor.profiles.first?.id == "p-obs")
        #expect(monitor.activeID == "p-obs")
    }

    /// Mirrors the actual user-bug scenario: PopoverView is mounted with the
    /// store empty (welcome panel state). Afterwards a profile arrives in the
    /// store, monitor.reloadProfiles() runs, and a *new* render of
    /// ProfileListView must see the profile — not whatever cached @State was
    /// captured at first init.
    @Test("ProfileListView body reflects monitor.profiles even when the view was first mounted with an empty store")
    func profileListBodyReflectsLatestMonitorProfiles() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(profileStore: store, slotStore: slot)
        let monitor = makeTestMonitor()
        monitor.environment = env

        // Mount the view while the store is still empty (this matches the
        // real production sequence: app launches → popover mounts → user
        // imports later).
        var captured: [Profile] = []
        _ProfileListReloadObserver.didReload = { captured = $0 }
        let renderer1 = ImageRenderer(content: ProfileListView(monitor: monitor))
        renderer1.proposedSize = ProposedViewSize(width: 320, height: nil)
        _ = renderer1.cgImage
        // Empty at this point.
        #expect(captured.isEmpty)

        // User runs `codex login` → an import lands in the store.
        let snap = AuthJSON(tokens: AuthTokens(idToken: "h.eyJlbWFpbCI6InRAeC5jb20ifQ.s", accessToken: "a", refreshToken: "r", accountID: "a-late"))
        let profile = Profile(id: "p-late", label: "late@example.com", dedupKey: "u::a-late", planType: "plus")
        try store.insert(profile, snapshot: snap)
        try slot.setActiveID(profile.id)

        // Production path: monitor.reloadProfiles() runs (called from
        // ProfileListView's import handler post-fix). This must propagate to
        // any view reading monitor.profiles.
        monitor.reloadProfiles()
        #expect(monitor.profiles.count == 1)

        // Re-render the view. Pre-fix: `@State profiles` is stuck at [] from
        // the first render. Post-fix: body reads monitor.profiles, which is
        // now [profile], and the observer captures it.
        captured = []
        let renderer2 = ImageRenderer(content: ProfileListView(monitor: monitor))
        renderer2.proposedSize = ProposedViewSize(width: 320, height: nil)
        _ = renderer2.cgImage
        _ProfileListReloadObserver.didReload = nil

        #expect(captured.count == 1, "ProfileListView did not pick up the late-arriving profile from monitor.profiles; saw \(captured.count). Stale @State suspected.")
        #expect(captured.first?.id == "p-late")
    }
}
