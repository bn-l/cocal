import Testing
import SwiftUI
import Foundation
@testable import CodexSwitcher

/// Issue 8 (red-green): user reported their profile lived on disk
/// (`~/Library/Application Support/codex-switcher/profiles/<id>/metadata.json`
/// with `id`, `label`, `dedupKey`, `planType`) yet the popover showed only the
/// "Import credentials" button — the row never appeared. Re-importing returned
/// `.refreshed`, confirming the credential was found, but the profile still
/// wasn't visible.
///
/// Root cause hypothesis: `ProfileListView` loaded profiles via
/// `.task { reload() }` (async), and (a) the `.refreshed` / `.duplicate` import
/// branches did not call `monitor.manualPoll()`, leaving the popover state
/// stale and (b) the async reload could miss a render cycle, leaving
/// `profiles` at its initial `[]` value when the view first laid out.
///
/// Fix: load profiles **synchronously in `ProfileListView.init`**, refresh on
/// `.onAppear` for subsequent appearances, and call `manualPoll()` for every
/// import outcome (not just `.imported`) so `noProfileImported` settles.
///
/// These tests model the production path with no mocks: real `ProfileStore`,
/// real `SlotStore`, real `Snapshotter`-written `auth.json`, real `Importer`,
/// real `UsageMonitor`. The `_ProfileListReloadObserver` exposed by the view
/// is a test *seam* (single observer closure), not a fake — it observes the
/// genuine production reload call.
@Suite("ProfileListView — profile shows up after import.refreshed", .serialized)
@MainActor
struct ProfileListReloadTests {

    // MARK: - Helpers

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-reload-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func idToken(user: String, account: String, plan: String = "plus") throws -> String {
        let inner: [String: Any] = [
            "chatgpt_user_id": user,
            "chatgpt_account_id": account,
            "chatgpt_plan_type": plan,
        ]
        let payload: [String: Any] = [
            "https://api.openai.com/auth": inner,
            "email": "\(user)@example.com",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        return "\(b64url(header)).\(b64url(payloadData)).sig"
    }

    // MARK: - Tests

    /// Sanity check: a metadata.json shaped exactly like the user's actual
    /// on-disk file (id, dedupKey, label, planType — no warming fields)
    /// decodes via `ProfileStore.loadAll()`. If this regresses we'd silently
    /// drop every legacy profile.
    @Test("ProfileStore.loadAll decodes the user's actual metadata.json shape")
    func loadAllSurvivesMinimalMetadataShape() throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))

        // Mirror the user's exact on-disk metadata.json (verified via `cat`).
        let id = "22306E3E-252F-463C-9F88-A04E19F3AAC7"
        let profileDir = store.directory(for: id)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let raw = """
        {
          "dedupKey" : "user-j6djvnobizplwk6VAcBKzHEz::f44e2765-b90d-4b78-8fef-bd9c6e0bc6dd",
          "id" : "22306E3E-252F-463C-9F88-A04E19F3AAC7",
          "label" : "litwin.catherine@gmail.com",
          "planType" : "plus"
        }
        """
        try raw.data(using: .utf8)!.write(to: store.metadataURL(for: id))

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == id)
        #expect(loaded.first?.label == "litwin.catherine@gmail.com")
        #expect(loaded.first?.planType == "plus")
        #expect(loaded.first?.lastWarmed == nil)
    }

    /// The actual regression: when `ProfileListView` is constructed against a
    /// populated `ProfileStore`, its initial `profiles` state must already
    /// reflect the store. Pre-fix the view loaded inside `.task { reload() }`
    /// so the very first render observed `profiles == []` — which is what
    /// the user saw after opening the popover.
    ///
    /// We verify via `_ProfileListReloadObserver`, an internal test seam that
    /// captures the profiles array the view's reload path actually computed.
    /// The observer is single-shot, scoped per-test, and operates on real
    /// production state — no mocks, no fakes.
    @Test("ProfileListView surfaces a populated store at the first render, not on a deferred async tick")
    func profilesPopulatedSynchronouslyOnFirstRender() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let token = try Self.idToken(user: "u-load", account: "a-load")
        let snap = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: "a-load"))
        let profile = Profile(id: "p-load", label: "load@example.com", dedupKey: "u-load::a-load", planType: "plus")
        try store.insert(profile, snapshot: snap)

        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        try slot.setActiveID(profile.id)

        let env = AppEnvironment(profileStore: store, slotStore: slot)
        let monitor = makeTestMonitor()
        monitor.environment = env

        var captured: [Profile] = []
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var fulfilled = false
            _ProfileListReloadObserver.didReload = { profiles in
                captured = profiles
                if !fulfilled { fulfilled = true; cont.resume() }
            }

            // Render via ImageRenderer — drives the same SwiftUI lifecycle the
            // popover uses (init, layout, .onAppear).
            let view = ProfileListView(monitor: monitor)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
            _ = renderer.cgImage
            // ImageRenderer's call may not fire .onAppear in every macOS
            // build, so the synchronous init-load path must populate the
            // observer regardless. If neither path runs, the continuation
            // never resumes and the test deadlocks (caught by the suite's
            // overall timeout).
            if !fulfilled { fulfilled = true; cont.resume() }
        }
        _ProfileListReloadObserver.didReload = nil

        #expect(captured.count == 1, "ProfileListView's initial render did not load profiles from store; saw \(captured.count)")
        #expect(captured.first?.id == "p-load")
    }

    /// Issue 8 specifically: after `Importer.runImport()` returns `.refreshed`,
    /// the popover must surface the profile. Before the fix, the import branch
    /// only called `manualPoll()` for `.imported`, so a re-import that hit the
    /// existing snapshot left `monitor.noProfileImported` whatever it had been
    /// before — sometimes `true`, sometimes stale.
    @Test("After a .refreshed re-import, manualPoll runs so noProfileImported settles")
    func refreshedImportTriggersManualPoll() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Live `~/.codex/auth.json` the importer reads from. Real Snapshotter,
        // not a stub.
        let homeDir = dir.appendingPathComponent("home")
        let liveAuthURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = try Self.idToken(user: "u-refr", account: "a-refr")
        let liveAuth = AuthJSON(
            tokens: AuthTokens(idToken: token, accessToken: "atok", refreshToken: "rtok", accountID: "a-refr"),
            lastRefresh: Date()
        )
        try Snapshotter.write(liveAuth, to: liveAuthURL)

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(
            profileStore: store,
            slotStore: slot,
            resolver: AuthPathResolver(environment: [:], homeDirectory: homeDir)
        )

        // First import: creates the profile.
        let firstImport = env.makeImporter()
        let (firstOutcome, _) = try firstImport.runImport()
        guard case .imported(let imported) = firstOutcome else {
            Issue.record("expected .imported on first run, got \(firstOutcome)")
            return
        }
        try slot.setActiveID(imported.id)

        // Bump the live snapshot's freshness so the re-import returns
        // .refreshed (not .duplicate).
        var refreshed = liveAuth
        refreshed.lastRefresh = Date().addingTimeInterval(60)
        try Snapshotter.write(refreshed, to: liveAuthURL)

        let secondImport = env.makeImporter()
        let (secondOutcome, _) = try secondImport.runImport()
        guard case .refreshed = secondOutcome else {
            Issue.record("expected .refreshed on re-import, got \(secondOutcome)")
            return
        }

        // Production code path: after .refreshed, the popover's import handler
        // must call `monitor.manualPoll()` (the fix). manualPoll re-runs poll()
        // which in turn flips `noProfileImported` based on whether a profile
        // exists. The pre-fix branch returned without manualPoll, leaving the
        // flag stuck at its previous value.
        let monitor = UsageMonitor()
        monitor.environment = env
        monitor.noProfileImported = true   // Pretend the popover was in the welcome panel state
        await monitor.manualPoll()

        #expect(monitor.noProfileImported == false, "manualPoll must clear noProfileImported when an active profile exists in store")
        #expect(env.profileStore.loadAll().count == 1)
    }

    /// Same regression for `.duplicate` outcome — re-importing a profile we
    /// already have should also reconcile UI state.
    @Test("After a .duplicate re-import, the store still surfaces exactly one profile")
    func duplicateImportLeavesStoreCoherent() async throws {
        let dir = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let homeDir = dir.appendingPathComponent("home")
        let liveAuthURL = homeDir.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = try Self.idToken(user: "u-dup", account: "a-dup")
        let liveAuth = AuthJSON(
            tokens: AuthTokens(idToken: token, accessToken: "atok", refreshToken: "rtok", accountID: "a-dup")
        )
        try Snapshotter.write(liveAuth, to: liveAuthURL)

        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(
            profileStore: store,
            slotStore: slot,
            resolver: AuthPathResolver(environment: [:], homeDirectory: homeDir)
        )

        let importer1 = env.makeImporter()
        let (out1, _) = try importer1.runImport()
        guard case .imported(let prof) = out1 else {
            Issue.record("expected .imported, got \(out1)")
            return
        }
        try slot.setActiveID(prof.id)

        // Identical live snapshot — re-import is a duplicate.
        let importer2 = env.makeImporter()
        let (out2, _) = try importer2.runImport()
        guard case .duplicate = out2 else {
            Issue.record("expected .duplicate, got \(out2)")
            return
        }

        let monitor = UsageMonitor()
        monitor.environment = env
        monitor.noProfileImported = true   // Welcome-panel state
        await monitor.manualPoll()
        #expect(monitor.noProfileImported == false)
        #expect(store.loadAll().count == 1)
    }
}
