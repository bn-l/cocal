import Testing
import Foundation
@testable import CodexSwitcher

@Suite("TokenRefresher.classifyFailure")
struct TokenRefresherClassifyTests {

    @Test("refresh_token_expired → .expired")
    func mapsExpired() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"refresh_token_expired"}"#)
        #expect(reason == .expired)
    }

    @Test("refresh_token_reused → .exhausted (the single-use rotation gotcha)")
    func mapsExhausted() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"refresh_token_reused"}"#)
        #expect(reason == .exhausted)
    }

    @Test("invalid_grant → .revoked when no more specific reason supplied")
    func mapsRevoked() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"invalid_grant"}"#)
        #expect(reason == .revoked)
    }

    @Test("Unknown 5xx body → .other")
    func mapsOther() {
        let reason = TokenRefresher.classifyFailure(status: 503, body: "service unavailable")
        #expect(reason == .other)
    }

    @Test("Profile warning maps from refresh failure cleanly")
    func warningMapping() {
        #expect(ProfileWarning(refreshFailure: .expired) == .refreshExpired)
        #expect(ProfileWarning(refreshFailure: .exhausted) == .refreshExhausted)
        #expect(ProfileWarning(refreshFailure: .revoked) == .refreshRevoked)
        #expect(ProfileWarning(refreshFailure: .other) == .unknown)
    }
}
