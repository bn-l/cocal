import Foundation

/// Selection logic for the auto-switch flow (PLAN.md §2.3 "Auto-switch on low usage").
///
/// **No lexical fallback.** A candidate must satisfy *all three* of:
///   - fresh: most recent warm within `2 × warmerInterval` (default 14 days)
///   - healthy: no active warning state
///   - low usage: warmed primary utilization ≤ `lowUsagePercent` (default 50%)
///
/// The previous lexical-fallback design was unsafe — under usage pressure it could
/// pick an `Expired`/`Exhausted`/`Revoked` profile precisely when re-login is hardest.
public struct AutoSwitchPicker: Sendable {
    public let warmerInterval: TimeInterval
    public let lowUsagePercent: Double
    public let now: @Sendable () -> Date

    public init(
        warmerInterval: TimeInterval = 7 * 24 * 60 * 60,
        lowUsagePercent: Double = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.warmerInterval = warmerInterval
        self.lowUsagePercent = lowUsagePercent
        self.now = now
    }

    /// Returns the profile that wins, or `nil` to abort (caller should notify the user).
    public func pick(among candidates: [Profile], excluding excludedID: String?) -> Profile? {
        let cutoff = now().addingTimeInterval(-2 * warmerInterval)
        return candidates.first { p in
            guard p.id != excludedID else { return false }
            guard p.warning == nil else { return false }
            guard let lastWarmed = p.lastWarmed, lastWarmed >= cutoff else { return false }
            guard let used = p.primaryUsedPercent, used <= lowUsagePercent else { return false }
            return true
        }
    }
}
