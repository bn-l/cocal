import Testing
import Foundation

/// Issue (red-green round 2): the auto-switch control "is not a button. At
/// least it doesn't look like a button. It should be a toggle button …
/// clicking it makes it solid". PLAN.md Appendix A confirms the contract:
/// "filled when ON, outlined when OFF".
///
/// SwiftUI ships a built-in for exactly this: `Toggle(...)` with
/// `.toggleStyle(.button)`. The toggle renders as a button-shaped control,
/// `.bordered` style when off and `.borderedProminent` when on, with the
/// fill state driving the on/off look. We assert the source uses this
/// idiom rather than the previous `Button { ... }` that toggled
/// `autoSwitchEnabled` and only changed text colour.
@Suite("Auto-switch — uses Toggle(.button) so it actually looks like a toggle button")
struct AutoSwitchToggleButtonTests {

    private static func popoverSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/PopoverView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("PopoverView wires up Toggle(...).toggleStyle(.button) for auto-switch")
    func usesToggleStyleButton() throws {
        let src = try Self.popoverSource()
        // The Toggle binds to monitor.autoSwitchEnabled, labels itself "Auto
        // switch", and uses .toggleStyle(.button) so it renders solid-on /
        // outlined-off. Pre-fix the control was `Button { … } label:
        // { Text("Auto-switch: on") }` which the user reports doesn't look
        // like a button.
        #expect(src.contains("Toggle("), "Auto-switch should use SwiftUI Toggle, not a plain Button")
        #expect(src.contains(".toggleStyle(.button)"), "Auto-switch Toggle must use .toggleStyle(.button) for the filled/outlined look")
        #expect(src.contains("\"Auto switch\""), "Auto-switch label should read \"Auto switch\" — current copy is wrong")
        #expect(src.contains("$monitor.autoSwitchEnabled") || src.contains("monitor.autoSwitchEnabled"),
                "Toggle must bind to monitor.autoSwitchEnabled")
    }

    /// Belt-and-suspenders: the previous Button-with-Text-label is gone.
    /// Leaving both around is a regression hazard if a future edit re-wires
    /// the wrong control.
    @Test("Old icon-button auto-switch text labels are not present anywhere")
    func oldButtonLabelStringsRemoved() throws {
        let src = try Self.popoverSource()
        #expect(!src.contains("\"Auto-switch: on\""), "Stale text-button auto-switch label found")
        #expect(!src.contains("\"Auto-switch: off\""), "Stale text-button auto-switch label found")
    }
}
