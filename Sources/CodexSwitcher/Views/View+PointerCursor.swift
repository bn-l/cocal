import SwiftUI
import AppKit

/// Drives the macOS mouse cursor to the pointing hand while hovering.
///
/// ### Why this is hard in a MenuBarExtra popover
///
/// Menu-bar popover windows (NSPanel) are not the key window, and macOS
/// resets cursor changes made via NSCursor on every render pass. Previous
/// attempts that all failed:
///
/// 1. `.pointerStyle(.link)` — iPadOS-primary; flashes then reverts on macOS
/// 2. `.onHover + NSCursor.set()` — overridden by the popover window
/// 3. `addCursorRect` overlay — popover window resets cursor rects
/// 4. `NSTrackingArea + cursorUpdate` overlay — SwiftUI gives the
///    NSViewRepresentable a zero-sized frame inside MenuBarExtra, so the
///    tracking area covers nothing
///
/// ### The fix
///
/// `onContinuousHover` (macOS 13+) combined with disabling cursor rects on
/// the popover window before setting the cursor. Disabling cursor rects
/// prevents the window from immediately resetting our NSCursor.set() call.
/// We re-enable on hover-out so normal cursor behaviour resumes.
///
/// Sources:
/// - Apple Developer Forums thread 739874, 708211, 96875
/// - Amzd gist (onContinuousHover + guard against duplicate pushes)
/// - "NSApp.windows.forEach { $0.disableCursorRects() }" workaround
extension View {
    /// Show `cursor` while hovering over this view. Works reliably inside
    /// `MenuBarExtra(.window)` popover panels.
    func pointerCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                guard NSCursor.current != cursor else { return }
                // Prevent the popover window from resetting the cursor
                // on its next layout pass. This is an acknowledged
                // workaround for non-key windows (Apple Dev Forums).
                for window in NSApp.windows {
                    window.disableCursorRects()
                }
                cursor.set()
            case .ended:
                NSCursor.arrow.set()
                for window in NSApp.windows {
                    window.enableCursorRects()
                }
            @unknown default:
                break
            }
        }
    }
}
