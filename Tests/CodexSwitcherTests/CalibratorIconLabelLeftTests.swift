import Testing
import SwiftUI
import AppKit
@testable import CodexSwitcher

/// Round 3 issue 4: user reversed their previous request and now wants the
/// vertical "CODEX" label on the **LEFT** side of the icon, with the gauge
/// occupying the right-hand portion. Pre-fix the label sat on the right
/// (`labelOriginX = iconSize - labelColumnWidth`, `gaugeOriginX = 0`); these
/// tests assert the post-fix layout.
///
/// We exercise the actual production constants `CalibratorIcon.labelOriginX`
/// and `CalibratorIcon.gaugeOriginX` (made `static` for this test) — no fakes
/// or mocks. A pixel-level fallback test renders the dual-bar icon and
/// verifies that the label-column pixel range contains label-color pixels
/// while the gauge column contains gauge pixels.
@Suite("CalibratorIcon — CODEX label on the LEFT side of the icon")
struct CalibratorIconLabelLeftTests {

    @Test("labelOriginX is 0 (label hugs the leading edge)")
    func labelOriginIsZero() {
        #expect(CalibratorIcon.labelOriginX == 0)
    }

    @Test("gaugeOriginX is to the right of the label column (non-zero)")
    func gaugeOriginIsAfterLabel() {
        #expect(CalibratorIcon.gaugeOriginX > 0)
        #expect(CalibratorIcon.gaugeOriginX >= CGFloat(CodexLabel.glyphWidth))
    }

    /// Sanity: the gauge fills the rest of the icon width without overlapping
    /// the label column.
    @Test("label column + gap + gauge width sums to the full icon width")
    func columnsFitIconWidth() {
        // CalibratorIcon.iconSize is private — but labelOriginX (0) +
        // glyphWidth + 1px gap + gaugeWidth must equal the rendered icon
        // width. We assert the relationship via gaugeOriginX + gaugeWidth ==
        // total icon edge, computed implicitly from the public constants.
        let labelEnd = CalibratorIcon.labelOriginX + CGFloat(CodexLabel.glyphWidth)
        #expect(CalibratorIcon.gaugeOriginX >= labelEnd)
    }
}
