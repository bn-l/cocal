import Testing
import Foundation
@testable import CodexSwitcher

@Suite("AutoSwitchPicker")
struct AutoSwitchPickerTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func profile(
        id: String = UUID().uuidString,
        used: Double?,
        warmedAgo seconds: TimeInterval?,
        warning: ProfileWarning? = nil
    ) -> Profile {
        var p = Profile(label: id, dedupKey: "u::\(id)")
        p.primaryUsedPercent = used
        p.lastWarmed = seconds.map { now.addingTimeInterval(-$0) }
        p.warning = warning
        return p
    }

    private static func picker() -> AutoSwitchPicker {
        AutoSwitchPicker(now: { Self.now })
    }

    @Test("Picks the first profile that is fresh, healthy, and low-usage")
    func picksHappyPath() {
        let candidates = [
            // Stale: warmed 30 days ago.
            Self.profile(used: 5, warmedAgo: 30 * 86400),
            // Fresh + low + healthy → wins.
            Self.profile(id: "winner", used: 12, warmedAgo: 1 * 86400),
            // Fresh but high usage.
            Self.profile(used: 80, warmedAgo: 1 * 86400),
        ]
        let chosen = Self.picker().pick(among: candidates, excluding: nil)
        #expect(chosen?.label == "winner")
    }

    @Test("Excludes warning-state profiles")
    func skipsWarning() {
        let candidates = [
            Self.profile(used: 10, warmedAgo: 86400, warning: .refreshExhausted),
            Self.profile(id: "ok", used: 20, warmedAgo: 86400),
        ]
        let chosen = Self.picker().pick(among: candidates, excluding: nil)
        #expect(chosen?.label == "ok")
    }

    @Test("Excludes the active profile via excludedID")
    func excludesActive() {
        let active = Self.profile(id: "active", used: 5, warmedAgo: 3600)
        let other = Self.profile(id: "other", used: 5, warmedAgo: 3600)
        let chosen = Self.picker().pick(among: [active, other], excluding: active.id)
        #expect(chosen?.id == other.id)
    }

    @Test("Returns nil when no candidate satisfies all three rules")
    func abortsWhenNobodyQualifies() {
        let candidates = [
            Self.profile(used: 80, warmedAgo: 86400),                  // too high
            Self.profile(used: 10, warmedAgo: 30 * 86400),             // too stale
            Self.profile(used: 10, warmedAgo: 86400, warning: .refreshRevoked),
        ]
        let chosen = Self.picker().pick(among: candidates, excluding: nil)
        #expect(chosen == nil)
    }

    @Test("Default freshness window is 2× warmerInterval (14 days for 7-day cadence)")
    func freshnessBoundary() {
        let p = AutoSwitchPicker(warmerInterval: 7 * 86400, now: { Self.now })
        // 13.5 days → still fresh.
        let fresh = Self.profile(used: 10, warmedAgo: 13.5 * 86400)
        // 14.1 days → just past the window.
        let stale = Self.profile(used: 10, warmedAgo: 14.1 * 86400)
        #expect(p.pick(among: [fresh], excluding: nil)?.id == fresh.id)
        #expect(p.pick(among: [stale], excluding: nil) == nil)
    }
}
