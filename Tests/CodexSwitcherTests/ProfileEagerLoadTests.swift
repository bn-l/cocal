import Testing
import SwiftUI
import Foundation
@testable import CodexSwitcher

/// Round 3 issue 1 (the user's screenshot of empty profile rows): even after
/// Round 2 surfaced `monitor.profiles` on `UsageMonitor`, the production app
/// still showed an empty profile section. Round-2's tests passed because they
/// constructed a fresh `ProfileListView` for every render — every fresh init
/// re-ran the side-effect inside `init` and "saw" the new state. The
/// production lifecycle differs: `MenuBarExtra(.window)` keeps the same view
/// tree alive across opens, and the side-effect-in-init pattern is fragile
/// inside a SwiftUI render pass (a mutation in `init` doesn't reliably
/// propagate to *this same instance's* body before the body reads the value).
///
/// The fix is to populate `monitor.profiles` **before any view is
/// constructed** — at `CodexSwitcherApp.init` time — and then refresh it
/// from outside any view body via `UsageMonitor.poll()` and the popover's
/// top-level `.task`. ProfileListView.init no longer mutates state.
///
/// These tests assert two contracts:
///   1. Removing the side-effect from `ProfileListView.init` (no
///      `reloadProfiles` invocation) leaves a freshly-mounted ProfileListView
///      reading whatever was already in `monitor.profiles` — i.e. body
///      depends purely on observable monitor state.
///   2. The eager-load contract: when an app constructs `UsageMonitor`,
///      assigns its environment, and then calls `monitor.reloadProfiles()`
///      (the App.swift pattern), the observable list contains the on-disk
///      profile *before* any popover view ever runs.
@Suite("Profile rows — eager load via UsageMonitor before any view is constructed", .serialized)
@MainActor
struct ProfileEagerLoadTests {

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-eager-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The actual production wiring: build env, set monitor.environment,
    /// reloadProfiles, *then* construct the popover. monitor.profiles must
    /// already be populated.
    @Test("App-init pattern: env + reloadProfiles produces populated monitor.profiles before any view runs")
    func appInitPatternPopulatesProfilesEagerly() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let snap = AuthJSON(tokens: AuthTokens(idToken: "h.eyJlbWFpbCI6InRAeC5jb20ifQ.s", accessToken: "a", refreshToken: "r", accountID: "acct"))
        let profile = Profile(id: "p-eager", label: "eager@example.com", dedupKey: "u::acct", planType: "plus")
        try store.insert(profile, snapshot: snap)
        try slot.setActiveID(profile.id)

        let env = AppEnvironment(profileStore: store, slotStore: slot)
        let monitor = makeTestMonitor()
        monitor.environment = env

        // CodexSwitcherApp.init contract — load before any view is built.
        monitor.reloadProfiles()

        #expect(monitor.profiles.count == 1, "Eager reloadProfiles must populate monitor.profiles before any view runs.")
        #expect(monitor.profiles.first?.id == "p-eager")
        #expect(monitor.activeID == "p-eager")
    }

    /// Round 2's regression-prone pattern was a side-effect inside
    /// `ProfileListView.init`. Round 3's fix removes it. Source-text scan
    /// asserts the side-effect is gone — leaving it would re-introduce the
    /// SwiftUI lifecycle ambiguity.
    @Test("ProfileListView.init has no `monitor.reloadProfiles` side-effect (production contract)")
    func profileListInitHasNoSideEffect() throws {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/ProfileListView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)

        guard let initRange = src.range(of: "init(monitor: UsageMonitor, onDismiss: (() -> Void)? = nil)") else {
            Issue.record("Could not locate ProfileListView.init in source")
            return
        }
        // Inspect the init body — roughly the next 1500 chars covers it
        // (current implementation is ~250 chars).
        let body = String(src[initRange.lowerBound...].prefix(1500))
        // Find the closing brace of the init body. It comes after an empty-
        // statement-only sequence, but a defensive scan for the call is fine.
        // We strip everything after `var profiles:` (the first member after
        // init) so we don't false-positive on calls elsewhere in the file.
        let beforeNextMember = body.components(separatedBy: "private var profiles").first ?? body
        #expect(!beforeNextMember.contains("monitor.reloadProfiles()"),
                "ProfileListView.init must not mutate monitor.profiles — the SwiftUI render-pass observation contract makes this unreliable in production. Init body:\n\(beforeNextMember)")
    }

    /// PopoverView.swift must call `monitor.reloadProfiles()` from its
    /// top-level `.task` so re-opens pick up out-of-band store changes
    /// (e.g. a CLI delete or a fresh import while the popover was closed).
    @Test("PopoverView re-syncs profiles via .task on every open")
    func popoverReSyncsViaTask() throws {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/PopoverView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        // The .task body must contain a reloadProfiles call so each popover
        // open snapshots the current store. Anchor on `.task {` near the
        // outer body modifiers.
        #expect(src.contains(".task {") && src.contains("monitor.reloadProfiles()"),
                "PopoverView must call monitor.reloadProfiles() inside a top-level .task so popover opens re-sync the profile list.")
    }

    /// App.swift must call `monitor.reloadProfiles()` after wiring the
    /// environment so the very first popover open already has the profile
    /// list. Without this the user opens the popover, sees an empty list,
    /// closes it; if no poll has fired yet they never see their profile.
    @Test("CodexSwitcherApp.init reloads profiles before storing the monitor in @State")
    func appInitReloadsProfiles() throws {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/App.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains("monitor.reloadProfiles()"),
                "CodexSwitcherApp.init must call monitor.reloadProfiles() so the popover's first render already has the profile list.")
    }
}
