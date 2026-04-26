import Testing
import Foundation

/// Round 3/4 issues: user wants the Auto-switch toggle button to have a
/// **different colour** (not the default accent) and **smaller text**.
///
/// Strategy: `.tint(.purple)` sets the on-state fill on a button-styled
/// Toggle, and `.controlSize(.mini)` shrinks the chrome/text.
///
/// Tooltip: Round-3 added a custom `.shortHelp()` overlay that slid in,
/// covered items, and was transparent. Round-4 reverted to native `.help()`
/// which has none of those problems. The system delay (~1.5 s) is not
/// customizable via public SwiftUI API.
@Suite("Auto-switch toggle — distinct colour + smaller text")
struct AutoSwitchStyleTests {

    private static func popoverSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/PopoverView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Auto-switch Toggle uses .tint(...) for a distinct colour")
    func toggleHasDistinctTint() throws {
        let src = try Self.popoverSource()
        guard let range = src.range(of: "Toggle(\"Auto switch\"") else {
            Issue.record("Auto-switch Toggle not found in PopoverView.swift")
            return
        }
        let block = String(src[range.lowerBound...].prefix(600))
        #expect(block.contains(".tint("),
                "Auto-switch Toggle must use .tint(...) for a non-default colour. Block: \n\(block)")
    }

    @Test("Auto-switch Toggle uses .controlSize(.mini) for smaller text")
    func toggleUsesMiniControlSize() throws {
        let src = try Self.popoverSource()
        guard let range = src.range(of: "Toggle(\"Auto switch\"") else {
            Issue.record("Auto-switch Toggle not found in PopoverView.swift")
            return
        }
        let block = String(src[range.lowerBound...].prefix(600))
        #expect(block.contains(".controlSize(.mini)"),
                "Auto-switch Toggle must use .controlSize(.mini); pre-fix used .small.")
    }

    /// Footer tooltips must use native `.help(...)` — the Round-3 custom
    /// `.shortHelp()` overlay slid in, covered adjacent items, and was
    /// semi-transparent (Round-4 feedback). The system `.help()` avoids all
    /// three issues.
    @Test("Footer tooltips use native .help(...)")
    func footerTooltipsUseHelp() throws {
        let src = try Self.popoverSource()
        guard let range = src.range(of: "// Footer:") else {
            Issue.record("Footer marker comment not found — check whether the footer was rewritten.")
            return
        }
        let footer = String(src[range.lowerBound...].prefix(4000))
        let helps = footer.components(separatedBy: ".help(").count - 1
        #expect(helps >= 4,
                "Expected >= 4 `.help(...)` calls in the footer (one per icon button + toggle); found \(helps).")
        // shortHelp is gone — its overlay was broken (slides, covers, transparent).
        let shortHelps = footer.components(separatedBy: ".shortHelp(").count - 1
        #expect(shortHelps == 0,
                "Footer still uses broken .shortHelp() on \(shortHelps) item(s); must use native .help().")
    }
}
