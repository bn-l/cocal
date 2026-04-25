import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Warmer")

/// Background refresh of inactive profiles (PLAN.md §2.3 "Profile warmer").
///
/// Per profile, the warmer:
///   1. Calls `PerProfile.refreshIfNeeded()` so the access-token JWT is fresh and
///      any rotated refresh-token is persisted *immediately* — single-use rotation
///      is the whole reason the actor exists.
///   2. Calls `PerProfile.usage()` to cache the most recent rate-limit windows.
///   3. Calls `PerProfile.accountsCheck()` to keep the plan tier up to date.
///   4. Updates the profile's `metadata.json` with the cached numbers + warning state.
///
/// All side effects funnel through `PerProfile`; the warmer never writes the live
/// `~/.codex/auth.json` (only the active swap does that — PLAN.md §2.3).
public actor Warmer {
    private let store: ProfileStore
    private let now: @Sendable () -> Date

    public init(store: ProfileStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Refresh + poll a single profile. Returns the updated `Profile` so the caller
    /// can refresh the popover view without re-reading the metadata file.
    @discardableResult
    public func warm(profile: Profile, actor perProfile: PerProfile) async -> Profile {
        var updated = profile
        do {
            try await perProfile.refreshIfNeeded()
            updated.warning = nil
        } catch let BackendError.refreshFailure(reason) {
            logger.warning("Refresh failed for profile=\(profile.id, privacy: .public): \(reason.rawValue, privacy: .public)")
            updated.warning = ProfileWarning(refreshFailure: reason)
            try? store.updateMetadata(updated)
            return updated
        } catch {
            logger.warning("Refresh transport error profile=\(profile.id, privacy: .public): \(String(describing: error), privacy: .public)")
            updated.warning = .unknown
            try? store.updateMetadata(updated)
            return updated
        }

        if let usage = try? await perProfile.usage() {
            let resolved = usage.resolvedWindows
            updated.primaryUsedPercent = resolved.primary?.usedPercent
            updated.secondaryUsedPercent = resolved.secondary?.usedPercent
        }
        if let accounts = try? await perProfile.accountsCheck() {
            updated.planType = accounts.accounts?.first?.planType
                ?? accounts.account?.planType
                ?? updated.planType
        }
        updated.lastWarmed = now()
        try? store.updateMetadata(updated)
        return updated
    }
}
