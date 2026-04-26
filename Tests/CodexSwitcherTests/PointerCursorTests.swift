import Testing
import Foundation

/// Issue 1 (red-green, round 2): every interactible item in the popover
/// should show the pointing-hand cursor on hover. The first attempt used
/// `.pointerStyle(.link)` (macOS 15+ SwiftUI API), but the user reports it
/// "flashes for an instant" then reverts — that API is primarily aimed at
/// iPadOS/visionOS pointer hover effects and is not reliable for swapping
/// the macOS mouse cursor on `Button` controls.
///
/// The robust macOS-native approach is to drive `NSCursor` directly via
/// `.onHover { ... NSCursor.pointingHand.set() / NSCursor.arrow.set() ... }`
/// — that's how AppKit views set hover cursors and how SwiftUI bridges to
/// them. We expose this as `.pointerCursor()` so view code can opt every
/// interactive control in with one modifier call.
///
/// This source-text invariant verifies every `Button` and every
/// `.onTapGesture` in the popover-facing view files carries a
/// `.pointerCursor()` modifier — no `.pointerStyle(.link)` allowed (its
/// presence is a regression from the round-1 fix).
@Suite("Pointer cursor — every interactive control uses NSCursor-backed .pointerCursor()")
struct PointerCursorTests {

    private static func sourceURL(_ relative: String) -> URL {
        // Resolve relative to the test file itself so the assertion works
        // regardless of where `swift test` is invoked from.
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()        // Tests/CodexSwitcherTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // package root
            .appendingPathComponent("Sources/CodexSwitcher/\(relative)")
    }

    private static func read(_ relative: String) throws -> String {
        let url = sourceURL(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Count regex matches in the body of a Swift source file.
    private static func count(_ pattern: String, in text: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    @Test("PopoverView.swift: every Button + onTapGesture pairs with .pointerCursor()")
    func popoverButtonsHavePointerCursor() throws {
        let source = try Self.read("Views/PopoverView.swift")
        let buttons = try Self.count(#"Button\s*[\{(]"#, in: source)
        let taps = try Self.count(#"\.onTapGesture\s*[\{(]"#, in: source)
        let pointer = try Self.count(#"\.pointerCursor\(\)"#, in: source)
        let interactive = buttons + taps
        #expect(
            pointer >= interactive,
            "PopoverView.swift has \(interactive) interactive controls (\(buttons) Button + \(taps) onTapGesture) but only \(pointer) `.pointerCursor()` modifiers — the cursor will stay as an arrow on hover. Add `.pointerCursor()` to each interactive control."
        )
    }

    @Test("ProfileListView.swift: every Button + onTapGesture pairs with .pointerCursor()")
    func profileListButtonsHavePointerCursor() throws {
        let source = try Self.read("Views/ProfileListView.swift")
        let buttons = try Self.count(#"Button\s*[\{(]"#, in: source)
        let taps = try Self.count(#"\.onTapGesture\s*[\{(]"#, in: source)
        let pointer = try Self.count(#"\.pointerCursor\(\)"#, in: source)
        let interactive = buttons + taps
        #expect(
            pointer >= interactive,
            "ProfileListView.swift has \(interactive) interactive controls (\(buttons) Button + \(taps) onTapGesture) but only \(pointer) `.pointerCursor()` modifiers — clickable rows and trash buttons will not flip the cursor to the pointing hand."
        )
    }

    /// `.pointerStyle(.link)` was the round-1 fix but doesn't reliably
    /// change the mouse cursor on macOS Buttons. Its continued presence in
    /// these files would mask the real fix: assert it has been fully removed.
    @Test("Stale .pointerStyle(.link) modifier has been removed from all popover-facing views")
    func noPointerStyleLink() throws {
        let popover = try Self.read("Views/PopoverView.swift")
        let profileList = try Self.read("Views/ProfileListView.swift")
        #expect(!popover.contains(".pointerStyle(.link)"), "PopoverView still uses unreliable .pointerStyle(.link)")
        #expect(!profileList.contains(".pointerStyle(.link)"), "ProfileListView still uses unreliable .pointerStyle(.link)")
    }

    /// Verify the `.pointerCursor()` helper uses `onContinuousHover` +
    /// `disableCursorRects` to survive inside MenuBarExtra popover panels.
    /// Earlier approaches all failed because the popover window resets
    /// cursor state:
    /// - `.pointerStyle(.link)` — iPadOS-primary, flashes on macOS
    /// - `.onHover + NSCursor.set()` — reset by window
    /// - `addCursorRect` overlay — reset by window
    /// - `NSTrackingArea + cursorUpdate` — NSViewRepresentable gets zero
    ///   frame inside MenuBarExtra, so tracking area covers nothing
    @Test("PointerCursor helper uses onContinuousHover + disableCursorRects for MenuBarExtra reliability")
    func pointerCursorHelperUsesContinuousHover() throws {
        let here = URL(fileURLWithPath: #filePath)
        let helper = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexSwitcher/Views/View+PointerCursor.swift")
        let text = try String(contentsOf: helper, encoding: .utf8)
        #expect(text.contains("NSCursor.pointingHand") || text.contains(".pointingHand"), "Must use pointingHand cursor")
        #expect(text.contains("onContinuousHover"), "Must use onContinuousHover (not .onHover or NSTrackingArea — both fail in MenuBarExtra)")
        #expect(text.contains("disableCursorRects"), "Must disable cursor rects on the window to prevent the popover from resetting the cursor")
        #expect(text.contains("func pointerCursor"), "Must expose a pointerCursor() View modifier")
    }
}
