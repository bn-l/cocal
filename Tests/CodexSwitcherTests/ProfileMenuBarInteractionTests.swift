import Testing
import Foundation

@Suite("Profile menu-bar interactions")
struct ProfileMenuBarInteractionTests {
    private static func profileListSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/ProfileListView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func popoverSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/PopoverView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Profile removal confirmation is inline, not a transient confirmationDialog")
    func removalConfirmationIsInline() throws {
        let source = try Self.profileListSource()

        #expect(!source.contains(".confirmationDialog("),
                "MenuBarExtra windows dismiss when interacting with confirmationDialog; removal confirmation must stay inline in the popover.")
        #expect(source.contains("pendingRemovalConfirmation"),
                "ProfileListView should render an inline pendingRemovalConfirmation view.")
    }

    @Test("Warning profiles expose their error on click")
    func warningProfilesExposeErrorOnClick() throws {
        let source = try Self.profileListSource()

        #expect(source.contains("onWarning"),
                "ProfileRow should expose a warning click action instead of relying only on .help().")
        #expect(source.contains("warning.humanDescription"),
                "Clicking a warning profile should surface ProfileWarning.humanDescription visibly.")
    }

    @Test("Error state wins over stale metrics")
    func errorStateWinsOverStaleMetrics() throws {
        let source = try Self.popoverSource()
        guard let errorRange = source.range(of: "else if monitor.hasError"),
              let metricsRange = source.range(of: "else if let metrics = monitor.metrics") else {
            Issue.record("Could not find mainContent error/metrics branches")
            return
        }

        #expect(errorRange.lowerBound < metricsRange.lowerBound,
                "When a poll fails, PopoverView must not keep showing stale metrics such as a previous 100% session value.")
    }

    @Test("Identity mismatch message points to import, not codex login")
    func identityMismatchRecoveryCopy() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Services/UsageMonitor.swift"), encoding: .utf8)

        guard let range = source.range(of: "ProfileSnapshotIdentityError") else {
            Issue.record("Could not find ProfileSnapshotIdentityError handling in UsageMonitor.swift")
            return
        }
        let block = String(source[range.lowerBound...].prefix(900)).lowercased()
        #expect(block.contains("import credentials"),
                "Identity mismatch recovery should first point to Import credentials. Block:\n\(block)")
        #expect(!block.contains("codex login"),
                "Identity mismatch recovery should not default to telling the user to run codex login. Block:\n\(block)")
    }
}
