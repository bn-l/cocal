import Testing
import SwiftUI
@testable import CodexSwitcher

/// Issue 5: the stats popover content area was capped at 260pt, forcing the
/// last section ("Weekly Utilization", up to 6 rows) to scroll out of view on
/// any account with multi-week history. The height needs to be tall enough to
/// show all three sections (avg session usage, hours active, weekly history)
/// without requiring scroll on a typical account.
@Suite("StatsView size")
@MainActor
struct StatsViewSizeTests {

    @Test("ScrollView max height is at least 380pt so weekly history fits")
    func scrollMaxHeightIsTallEnough() {
        // The constant must be tall enough to reveal all three sections plus
        // padding on a populated account. 260pt clipped the bottom of weekly
        // history; 380 leaves room for ~6 weekly rows + the two prior
        // sections + the heading. If you need to tweak this, do it because
        // the layout grew, not to make the test pass.
        #expect(StatsView.scrollMaxHeight >= 380)
    }
}
