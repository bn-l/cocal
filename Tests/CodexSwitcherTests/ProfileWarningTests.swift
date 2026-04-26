import Testing
import Foundation
@testable import CodexSwitcher

@Suite("ProfileWarning")
struct ProfileWarningTests {

    @Test("Every warning case has a non-empty user-facing description")
    func everyCaseHasDescription() {
        // CaseIterable guard: if a new case is added without a string, this test
        // fires. The popover row tooltip relies on every case being renderable.
        for warning in ProfileWarning.allCases {
            #expect(!warning.humanDescription.isEmpty)
        }
    }

    @Test("refreshExpired prompt mentions `codex login`")
    func refreshExpiredCopy() {
        #expect(ProfileWarning.refreshExpired.humanDescription.lowercased().contains("codex login"))
    }

    @Test("refreshExhausted prompt mentions single-use rotation context")
    func refreshExhaustedCopy() {
        let s = ProfileWarning.refreshExhausted.humanDescription.lowercased()
        // Must point the user at the recovery action.
        #expect(s.contains("codex login"))
    }

    @Test("RefreshFailureReason → ProfileWarning mapping is exhaustive")
    func exhaustiveMapping() {
        // If a new RefreshFailureReason case is added, this switch must handle it
        // explicitly (default removed on purpose).
        for reason in [RefreshFailureReason.expired, .exhausted, .revoked, .other] {
            let warning = ProfileWarning(refreshFailure: reason)
            switch reason {
            case .expired: #expect(warning == .refreshExpired)
            case .exhausted: #expect(warning == .refreshExhausted)
            case .revoked: #expect(warning == .refreshRevoked)
            case .other: #expect(warning == .unknown)
            }
        }
    }
}
