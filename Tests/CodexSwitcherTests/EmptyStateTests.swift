import Testing
import Foundation
@testable import CodexSwitcher

/// First-run UX regression: when no Codex profile has been imported yet, the
/// popover should make Import the obvious next action — not "Unable to fetch
/// usage data" + a "View errors" link the user has to dig through.
///
/// These tests drive the actual `UsageMonitor.poll()` code path against a real
/// `AppEnvironment` rooted at temp directories — no mocks, no fakes. The
/// "no profile" branch in `UsageMonitor.poll` must surface a distinct state
/// that the popover can render as an empty-state import CTA.
@Suite("UsageMonitor — first-run no-profile state", .serialized)
@MainActor
struct EmptyStateTests {

    private static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switcher-empty-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeEmptyEnvironment() -> (AppEnvironment, URL) {
        let dir = tempDirectory()
        let store = ProfileStore(rootDirectory: dir.appendingPathComponent("profiles"))
        let slot = SlotStore(url: dir.appendingPathComponent("active-slot.json"))
        let env = AppEnvironment(
            profileStore: store,
            slotStore: slot,
            backend: BackendClient(),
            refresher: TokenRefresher(),
            resolver: AuthPathResolver()
        )
        return (env, dir)
    }

    @Test("After a poll with zero imported profiles, monitor exposes a `noProfileImported` flag")
    func exposesNoProfileFlag() async {
        let (env, dir) = Self.makeEmptyEnvironment()
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = UsageMonitor()
        monitor.environment = env

        // Drive the actual poll path — same call sequence as App.swift.
        await monitor.manualPoll()

        // The popover branches on this flag to render the import CTA inline
        // (front and center) instead of "Unable to fetch usage data".
        #expect(monitor.noProfileImported == true)
    }

    @Test("After importing a profile, `noProfileImported` flips back to false")
    func flagClearsAfterImport() async throws {
        let (env, dir) = Self.makeEmptyEnvironment()
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = UsageMonitor()
        monitor.environment = env
        await monitor.manualPoll()
        #expect(monitor.noProfileImported == true)

        // Insert a profile directly via the real ProfileStore — same code path
        // as the Importer's success branch.
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncodedString()
        let payload = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "u1",
                "chatgpt_account_id": "acct-1",
            ],
            "email": "user@example.com",
        ])
        let token = "\(header).\(payload.base64URLEncodedString()).sig"
        let snap = AuthJSON(tokens: AuthTokens(idToken: token, accessToken: "a", refreshToken: "r", accountID: "acct-1"))
        let profile = Profile(id: "p1", label: "user@example.com", dedupKey: "u1::acct-1")
        try env.profileStore.insert(profile, snapshot: snap)

        await monitor.manualPoll()
        #expect(monitor.noProfileImported == false)
    }

    /// Issue 2: the "no active profile" branch must produce a log line. The
    /// `UsageMonitor.errors` array also receives a copy of the user-visible
    /// message (mentioning "Import"), which the empty-state UI uses as its
    /// guidance text. This test asserts both — the log line is verified
    /// indirectly by checking the message that's appended alongside it.
    @Test("No-profile branch records an Import-pointing message (mirrors the warning log)")
    func recordsImportMessage() async {
        let (env, dir) = Self.makeEmptyEnvironment()
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = UsageMonitor()
        monitor.environment = env
        await monitor.manualPoll()

        // The UI surfaces this as "Import credentials" copy; the same string
        // is logged so a developer reading os_log sees the same hint.
        #expect(monitor.errors.contains { $0.message.localizedCaseInsensitiveContains("import") })
    }

    @Test("noProfileImported is false until the first poll runs (initial state)")
    func defaultIsFalseBeforePoll() {
        // Important: the flag must NOT be `true` before poll() runs, otherwise
        // the menu icon would flicker into the empty state on every cold launch
        // before AppEnvironment is wired up.
        let monitor = UsageMonitor()
        #expect(monitor.noProfileImported == false)
    }
}

private extension Data {
    /// Base64URL encoding (no padding) — used to assemble fake id_tokens.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
