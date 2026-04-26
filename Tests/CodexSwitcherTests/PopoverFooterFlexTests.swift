import Testing
import Foundation

/// Round 3 issue 3: user wants the footer items spaced like CSS `flex
/// space-between` — no manual padding, no single trailing `Spacer()` shoving
/// everything to one side. Each adjacent pair of footer items must be
/// separated by an explicit `Spacer()` so SwiftUI distributes them evenly.
///
/// Pre-fix the footer ended with one `Spacer()` before "Quit", which left the
/// other icons clumped on the left. The post-fix structure is:
///
///     HStack(spacing: 0) { … item, Spacer(), item, Spacer(), …, Spacer(), Quit }
///
/// We assert this via a source-text scan because the alternative (rendering
/// the footer and reading frame origins) requires a full SwiftUI runtime
/// driver and would re-render every test pass. The scan is hermetic and fast.
@Suite("PopoverView footer — flex space-between (Spacer between every pair)")
struct PopoverFooterFlexTests {

    private static func popoverSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/PopoverView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// HStack must declare `spacing: 0` so SwiftUI doesn't add a fixed gap
    /// between every pair on top of our Spacers — that would break the
    /// flex-between visual.
    @Test("Footer HStack uses spacing: 0")
    func footerUsesZeroSpacing() throws {
        let src = try Self.popoverSource()
        #expect(src.contains("HStack(spacing: 0)"),
                "Footer HStack must use `HStack(spacing: 0)` so Spacer() owns the spacing arithmetic.")
    }

    /// At least 4 `Spacer(minLength: 0)` calls — between (refresh|toggle),
    /// (toggle|stats), (stats|auto-switch), and (auto-switch|quit). Restart
    /// adds a 5th when present. Pre-fix had one `Spacer()` total.
    @Test("Footer contains at least four Spacer() between adjacent items")
    func footerHasMultipleSpacers() throws {
        let src = try Self.popoverSource()
        // Find the footer HStack and count Spacers within ~80 lines after it.
        guard let hstackRange = src.range(of: "HStack(spacing: 0)") else {
            Issue.record("Could not locate footer HStack in PopoverView.swift")
            return
        }
        let footer = String(src[hstackRange.lowerBound...].prefix(3500))
        let spacers = footer.components(separatedBy: "Spacer(minLength: 0)").count - 1
        #expect(spacers >= 4,
                "Footer needs at least 4 `Spacer(minLength: 0)` between footer items for flex-between layout; found \(spacers).")
    }

    /// Belt-and-suspenders: the previous lonely `Spacer()` (no minLength)
    /// before "Quit" is gone. Leaving it would mean the flex-between is
    /// fighting a flex-end Spacer.
    @Test("No bare Spacer() left over before Quit")
    func noLoneTrailingSpacer() throws {
        let src = try Self.popoverSource()
        // Find the Quit button line, look at the preceding ~3 lines.
        guard let quitRange = src.range(of: "Button(\"Quit\")") else {
            Issue.record("Could not locate Quit button in footer")
            return
        }
        let before = String(src[..<quitRange.lowerBound].suffix(200))
        // The post-fix has `Spacer(minLength: 0)` immediately before Quit.
        // Pre-fix had bare `Spacer()`.
        #expect(!before.contains("                Spacer()\n                Button"),
                "Bare `Spacer()` immediately before Quit suggests the flex-between rewrite is incomplete.")
    }
}
