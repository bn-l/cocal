import Foundation

/// A persisted, named ChatGPT credential bundle (PLAN.md §2.3). Storage layout:
///
///   ~/Library/Application Support/codex-switcher/profiles/<id>/
///       auth.json          ← snapshot, mode 0600, plaintext
///       metadata.json      ← this struct minus the tokens
///
/// The `Profile` struct on its own holds **no token material** — tokens stay in the
/// `auth.json` snapshot file owned by the per-profile actor. That separation keeps
/// the popover view-model trivially `Sendable` and means we can render the profile
/// list without ever loading credentials into the SwiftUI process.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    /// Stable internal identifier (UUID). Used as the directory name for the snapshot.
    public let id: String

    /// User-visible label. Defaults to the account email pulled from the `id_token`
    /// at import time; the user can rename freely.
    public var label: String

    /// `chatgpt_user_id::chatgpt_account_id` (PLAN.md §2.3) — robust dedup key
    /// that doesn't change when the snapshot bytes rotate on every refresh.
    public let dedupKey: String

    /// Cached metadata from the most recent successful warm.
    public var lastWarmed: Date?
    public var planType: String?
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?

    /// Warning state from the last refresh attempt. `nil` means healthy.
    public var warning: ProfileWarning?

    public init(
        id: String = UUID().uuidString,
        label: String,
        dedupKey: String,
        lastWarmed: Date? = nil,
        planType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        warning: ProfileWarning? = nil
    ) {
        self.id = id
        self.label = label
        self.dedupKey = dedupKey
        self.lastWarmed = lastWarmed
        self.planType = planType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.warning = warning
    }
}

/// Why a profile is in the `⚠` warning state in the popover. Drives both the
/// auto-switch picker (PLAN.md §2.3 — warning profiles are excluded) and the
/// hover tooltip on the row.
public enum ProfileWarning: String, Codable, Sendable, Equatable, CaseIterable {
    case refreshExpired
    case refreshExhausted
    case refreshRevoked
    case snapshotUnreadable
    case accountMismatch
    case unknown

    public var humanDescription: String {
        switch self {
        case .refreshExpired:
            return "Refresh token expired. Run `codex login` for this account and re-import."
        case .refreshExhausted:
            return "Refresh token was reused (single-use rotation violated). Run `codex login` again."
        case .refreshRevoked:
            return "Credentials were revoked — likely you logged out elsewhere. Run `codex login` again."
        case .snapshotUnreadable:
            return "Stored credentials are unreadable. Re-import this profile."
        case .accountMismatch:
            return "Stored credentials no longer match the imported account. Re-import."
        case .unknown:
            return "Unknown error. Try a manual refresh; if it persists, re-import."
        }
    }

    public init(refreshFailure: RefreshFailureReason) {
        switch refreshFailure {
        case .expired: self = .refreshExpired
        case .exhausted: self = .refreshExhausted
        case .revoked: self = .refreshRevoked
        case .other: self = .unknown
        }
    }
}
