import Testing
import Foundation

/// Issue 4 (red-green): "The icons should have an info popup when hovered for
/// more than N ms." On macOS the standard hover-tooltip is `.help(...)`, which
/// the system gates on the user's accessibility delay setting (~1.5s).
///
/// Round 3 issue 5: the user asked for a **shorter** hover-info delay than the
/// system's ~1.5 s `.help` wait. We added `.shortHelp(...)` — an `onHover`-
/// driven overlay that wraps `.help(text)` for accessibility AND shows a
/// custom bubble after a shorter (default 0.35 s) delay. Either modifier
/// satisfies "has a hover tooltip".
///
/// The contract this test enforces: any `Button` whose label closure renders
/// an SF Symbol via `Image(systemName: ...)` and contains no accompanying
/// `Text(...)` / `Label(...)` text must have a tooltip modifier — either
/// `.help(...)` or `.shortHelp(...)` — in its trailing modifier chain.
/// Pre-fix the popover refresh button and the two `xmark.circle.fill` close
/// buttons had no tooltip at all.
///
/// We don't test text-label buttons (Quit, Restart Codex, Import credentials,
/// Auto-switch) — those communicate their action via the label itself.
@Suite("Tooltips — every icon-only Button has a .help() or .shortHelp() modifier")
struct IconTooltipTests {

    private static func sourceURL(_ relative: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/\(relative)")
    }

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: sourceURL(relative), encoding: .utf8)
    }

    /// Returns each icon-only Button's label-body and modifier chain.
    /// Brace-matched: handles `Button { ... } label: { ... } .modifier` blocks
    /// where each closure has at most one nested `{ ... }` pair.
    private static func iconOnlyButtons(in source: String) throws -> [(label: String, modifiers: String, snippet: String)] {
        // Action-closure: brace-matched up to one nested level.
        // Label-closure: same, then we capture its body (group 1).
        // Modifier-chain: zero-or-more lines starting with `.` after the label
        // closure's closing brace (group 2).
        let pattern = #"""
        (?xs)
        Button\s*\{
            (?:[^{}] | \{ [^{}]* \})*?
        \}
        \s*label:\s*\{
            ( (?: [^{}] | \{ [^{}]* \} )*? )
        \}
        ( (?: \s*\.[a-zA-Z][^\n]*\n )+ )
        """#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var out: [(String, String, String)] = []
        for m in matches {
            let label = ns.substring(with: m.range(at: 1))
            // Skip text-bearing buttons.
            if label.contains("Text(") || label.contains("Label(") { continue }
            // Skip Buttons whose label has no SF Symbol — a Button wrapping a
            // pure shape or ProgressView still wants a tooltip if it looks
            // icon-y, but the user's request was about icons specifically.
            guard label.contains("Image(systemName:") else { continue }
            let modifiers = ns.substring(with: m.range(at: 2))
            let snippet = ns.substring(with: m.range).prefix(140)
                .replacingOccurrences(of: "\n", with: " ")
            out.append((label, modifiers, String(snippet)))
        }
        return out
    }

    /// Either `.help(` or `.shortHelp(` in the modifier chain counts as a
    /// tooltip. Both call into `.help(text)` for accessibility under the
    /// hood, so VoiceOver users get the same hint either way.
    private static func hasTooltip(_ modifiers: String) -> Bool {
        modifiers.contains(".help(") || modifiers.contains(".shortHelp(")
    }

    @Test("PopoverView.swift: every icon-only Button has .help() or .shortHelp()")
    func popoverIconButtonsHaveHelp() throws {
        let source = try Self.read("Views/PopoverView.swift")
        let buttons = try Self.iconOnlyButtons(in: source)
        // Sanity: there are several icon-only buttons in the popover.
        #expect(buttons.count >= 3, "Expected to find ≥3 icon-only buttons in PopoverView, found \(buttons.count)")
        let missing = buttons.filter { !Self.hasTooltip($0.modifiers) }
        #expect(missing.isEmpty, "PopoverView icon-only Buttons without .help()/.shortHelp(): \n\(missing.map(\.snippet).joined(separator: "\n"))")
    }

    @Test("ProfileListView.swift: every icon-only Button has .help() or .shortHelp()")
    func profileListIconButtonsHaveHelp() throws {
        let source = try Self.read("Views/ProfileListView.swift")
        let buttons = try Self.iconOnlyButtons(in: source)
        #expect(buttons.count >= 1, "Expected to find ≥1 icon-only buttons in ProfileListView, found \(buttons.count)")
        let missing = buttons.filter { !Self.hasTooltip($0.modifiers) }
        #expect(missing.isEmpty, "ProfileListView icon-only Buttons without .help()/.shortHelp(): \n\(missing.map(\.snippet).joined(separator: "\n"))")
    }
}
