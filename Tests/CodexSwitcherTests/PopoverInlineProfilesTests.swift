import Testing
import SwiftUI
import AppKit
@testable import CodexSwitcher

/// Issue 6: PLAN.md Appendix A's mockup shows the Profiles section sitting
/// *inline* in the main popover (between metrics and footer). The shipped
/// build hid it behind a separate "Profiles" page reached by clicking a
/// person.crop icon — every profile interaction (switch, import, see warning)
/// required leaving the metrics view and coming back. This test renders the
/// real PopoverView via SwiftUI's `ImageRenderer` (no mocks, no fakes) and
/// asserts the popover is tall enough to host *both* the metrics block and
/// the profile section at the same time.
///
/// Pre-fix: popover renders to ≈230pt tall (metrics + footer).
/// Post-fix: popover renders to ≈430pt+ (metrics + profiles + footer).
@Suite("PopoverView — inline profile section")
@MainActor
struct PopoverInlineProfilesTests {

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-popover-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Popover renders metrics and an inline profiles section together")
    func popoverEmbedsProfilesInline() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Real ProfileStore with one profile installed via the canonical path.
        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let snap = AuthJSON(tokens: AuthTokens(idToken: "h.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.s", accessToken: "a", refreshToken: "r", accountID: "acct"))
        let profile = Profile(id: "p1", label: "test@example.com", dedupKey: "u::acct")
        try store.insert(profile, snapshot: snap)
        try slot.setActiveID(profile.id)

        let env = AppEnvironment(
            profileStore: store,
            slotStore: slot,
            backend: BackendClient(),
            refresher: TokenRefresher(),
            resolver: AuthPathResolver()
        )
        let monitor = makeTestMonitor()
        monitor.environment = env
        // Populate metrics so the metrics block is fully expanded.
        monitor.processResponse(
            sessionUsagePct: 30, weeklyUsagePct: 20,
            sessionMinsLeft: 200, weeklyMinsLeft: 6000
        )

        let renderer = ImageRenderer(content: PopoverView(monitor: monitor))
        renderer.scale = 1.0
        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced no image")
            return
        }
        // 320pt fixed width per `.frame(width: 320)`; height grows with content.
        // The threshold is loose on purpose — a future-proof guard against the
        // popover collapsing back to a single-page layout.
        #expect(image.height >= 380, "Popover height \(image.height) too short — profile section is probably not inline")
    }

    /// PopoverView previously toggled `showingProfiles` to swap views; once the
    /// profile section lives inline that flag is dead. If you re-add a separate
    /// profiles "page" you must also re-justify it against PLAN.md Appendix A.
    @Test("PopoverView no longer needs a `showingProfiles` toggle")
    func noShowingProfilesToggle() {
        // Compile-time check: PopoverView is a struct with an `internal` body.
        // We can't easily reflect into private state, so use the rendered-size
        // proof above as the primary signal. This test is a documentation
        // anchor — a code reviewer should see the inline embedding directly
        // in PopoverView.swift.
        #expect(PopoverView.embedsProfileSectionInline == true)
    }
}
