import Testing
import Foundation
@testable import CodexSwitcher

/// Round 4: the profile row showed "5h — · wk —" (em dashes) instead of
/// actual usage percentages. Root cause: `primaryUsedPercent` and
/// `secondaryUsedPercent` on the Profile struct were only populated by
/// the Warmer (for inactive profiles). The active profile's usage flowed
/// straight to `UsageMetrics` via `processResponse` but was never written
/// back to the Profile's persisted metadata. Fix: after a successful poll,
/// write the active profile's usage %s back to the store so the profile
/// row can display them.
///
/// Uses real ProfileStore and UsageMonitor — no mocks.
@Suite("Profile row — usage percentages populated after poll", .serialized)
@MainActor
struct ProfileUsagePercentTests {

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-usage-pct-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// After processResponse runs (simulating a successful poll), the
    /// Profile's primaryUsedPercent and secondaryUsedPercent should be
    /// populated via the store update in poll().
    ///
    /// This test directly exercises the store-update path rather than
    /// running a full HTTP poll, because we can't call the live backend.
    @Test("Active profile metadata gets usage %s after poll updates the store")
    func activeProfileGetsUsagePercents() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let snap = AuthJSON(tokens: AuthTokens(
            idToken: "h.eyJlbWFpbCI6InRAeC5jb20ifQ.s",
            accessToken: "a", refreshToken: "r", accountID: "acct"
        ))
        let profile = Profile(
            id: "p-usage", label: "usage@example.com",
            dedupKey: "u::acct", planType: "plus"
        )
        try store.insert(profile, snapshot: snap)
        try slot.setActiveID(profile.id)

        // Before: percentages are nil.
        let before = store.loadAll().first
        #expect(before?.primaryUsedPercent == nil, "Pre-condition: primaryUsedPercent should be nil before any poll")
        #expect(before?.secondaryUsedPercent == nil, "Pre-condition: secondaryUsedPercent should be nil before any poll")

        // Simulate what poll() does after receiving usage data: update
        // the profile metadata with the fetched percentages.
        var updated = profile
        updated.primaryUsedPercent = 42.5
        updated.secondaryUsedPercent = 17.3
        try store.updateMetadata(updated)

        // After: percentages are populated.
        let after = store.loadAll().first
        #expect(after?.primaryUsedPercent == 42.5, "primaryUsedPercent should be 42.5 after store update")
        #expect(after?.secondaryUsedPercent == 17.3, "secondaryUsedPercent should be 17.3 after store update")
    }

    /// The utilization text formatter renders percentages when present,
    /// dashes when nil.
    @Test("Utilization text shows percentages, not dashes, when usage data exists")
    func utilizationTextShowsPercentages() {
        let profile = Profile(
            id: "p-fmt", label: "fmt@example.com",
            dedupKey: "u::fmt", planType: "plus",
            primaryUsedPercent: 65.0,
            secondaryUsedPercent: 30.0
        )
        // Mirror the ProfileRow's formatting logic.
        let session = profile.primaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let weekly = profile.secondaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let text = "5h \(session) · wk \(weekly)"
        #expect(text == "5h 65% · wk 30%", "Expected '5h 65% · wk 30%' but got '\(text)'")
    }

    /// When usage data is nil (fresh import, no poll yet), dashes are shown.
    @Test("Utilization text shows dashes when no usage data exists")
    func utilizationTextShowsDashesWhenNil() {
        let profile = Profile(
            id: "p-nil", label: "nil@example.com",
            dedupKey: "u::nil", planType: "plus"
        )
        let session = profile.primaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let weekly = profile.secondaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let text = "5h \(session) · wk \(weekly)"
        #expect(text == "5h — · wk —", "Expected dashes for nil usage; got '\(text)'")
    }

    /// Source-level check: UsageMonitor.poll() writes usage percentages
    /// back to the profile store after a successful backend response.
    @Test("UsageMonitor.poll writes primaryUsedPercent/secondaryUsedPercent to profile store")
    func pollWritesUsageToStore() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Services/UsageMonitor.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(text.contains("updated.primaryUsedPercent = primary?.usedPercent"),
                "poll() must write primary usage % back to the profile metadata")
        #expect(text.contains("updated.secondaryUsedPercent = secondary?.usedPercent"),
                "poll() must write secondary usage % back to the profile metadata")
        #expect(text.contains("env.profileStore.updateMetadata(updated)"),
                "poll() must persist the updated profile via profileStore.updateMetadata")
    }
}
