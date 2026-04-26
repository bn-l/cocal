import Testing
import SwiftUI
import Foundation
@testable import CodexSwitcher

/// Issue (red-green round 2): clicking Import credentials surfaces a status
/// message ("Refreshed snapshot for ___") that *never goes away*. The user
/// has to dismiss the popover and reopen it to clear the line. Spec: the
/// message must appear (fade in) and then auto-dismiss (fade out) after a
/// short window.
///
/// Architectural fix: lift the import status onto `UsageMonitor` (which is
/// `@Observable` and therefore can drive a fade animation in any view that
/// reads it) and have `monitor.showImportStatus(_:autoDismissAfter:)` schedule
/// a cancel-aware task that clears the status once the delay elapses. The
/// `autoDismissAfter` parameter is exposed so tests can run with a tight
/// window (~50ms) without the test itself becoming flaky-slow.
@Suite("UsageMonitor — importStatus auto-dismiss", .serialized)
@MainActor
struct ImportStatusFadeTests {

    @Test("showImportStatus surfaces the status, then clears it after the configured delay")
    func showImportStatusClearsAfterDelay() async throws {
        let monitor = makeTestMonitor()
        let status = UsageMonitor.ImportStatus(message: "Refreshed snapshot for u@example.com", isError: false)

        monitor.showImportStatus(status, autoDismissAfter: 0.2)
        #expect(monitor.importStatus == status)

        // Wait past the delay (with a comfortable margin so the test isn't
        // flaky on slow CI hosts). The dismiss task uses Task.sleep internally;
        // under heavy load (parallel test suites, xcodebuild) the scheduler
        // may be 500ms+ late, so we budget 1.5s total.
        try await Task.sleep(for: .seconds(1.5))
        #expect(monitor.importStatus == nil, "Import status should have auto-dismissed by now; got \(String(describing: monitor.importStatus))")
    }

    @Test("Calling showImportStatus again with a new status replaces the existing message and resets the timer")
    func consecutiveCallsReplaceTheStatus() async throws {
        let monitor = makeTestMonitor()
        let first = UsageMonitor.ImportStatus(message: "First", isError: false)
        let second = UsageMonitor.ImportStatus(message: "Second", isError: false)

        // Long delay on first so we can verify the second call cancels it.
        monitor.showImportStatus(first, autoDismissAfter: 5.0)
        #expect(monitor.importStatus == first)

        monitor.showImportStatus(second, autoDismissAfter: 0.05)
        #expect(monitor.importStatus == second)

        try await Task.sleep(for: .seconds(0.4))
        #expect(monitor.importStatus == nil, "Second status should have auto-dismissed; got \(String(describing: monitor.importStatus))")
    }

    /// Sanity: the message Text is wired up with a `.transition(.opacity)` /
    /// `.animation(...)` modifier so SwiftUI fades it in/out. We assert the
    /// source rather than rasterizing pixels — the rendered fade is a visual
    /// detail that ImageRenderer captures only at a single time slice.
    @Test("ProfileListView source wires up an opacity transition for the status text")
    func sourceContainsOpacityTransition() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/ProfileListView.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(text.contains(".transition(.opacity"), "ProfileListView should apply .transition(.opacity) to the status message")
        #expect(text.contains(".animation("), "ProfileListView should apply .animation(...) to the status message")
    }
}
