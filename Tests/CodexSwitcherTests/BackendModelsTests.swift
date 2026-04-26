import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Backend Codable models")
struct BackendModelsTests {

    // The REAL shape returned by https://chatgpt.com/backend-api/wham/usage —
    // verified against `openai/codex` `codex-rs/codex-backend-openapi-models` and
    // the user's own logs ("Codex usage response missing primary window/secondary
    // window" with this app's previous decoder). The previous fixture used the
    // wrong key names (`rate_limits` plural, `primary`/`secondary` instead of
    // `primary_window`/`secondary_window`) which left both windows nil for every
    // real call.
    @Test("UsageResponse decodes the canonical rate_limit / *_window shape")
    func decodesCanonicalRateLimit() throws {
        let json = Data("""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   {"used_percent": 32.0, "limit_window_seconds": 18000, "reset_after_seconds": 7200,  "reset_at": 1771556400},
            "secondary_window": {"used_percent": 12.5, "limit_window_seconds": 604800,"reset_after_seconds": 302400,"reset_at": 1771833600}
          }
        }
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        let resolved = resp.resolvedWindows
        #expect(resolved.primary?.usedPercent == 32.0)
        #expect(resolved.secondary?.usedPercent == 12.5)
        // resetsAt must come back as an actual Date, not nil.
        #expect(resolved.primary?.resetsAt != nil)
        #expect(resolved.secondary?.resetsAt != nil)
    }

    @Test("UsageResponse keeps decoding the legacy `rate_limits` plural shape (back-compat)")
    func decodesLegacyRateLimitsShape() throws {
        let json = Data("""
        {
          "rate_limits": {
            "primary":   {"used_percent": 32.0, "window": "5h_rolling", "resets_at": "2026-01-15T12:00:00Z", "limit": 1000, "used": 320, "remaining": 680},
            "secondary": {"used_percent": 12.5, "window": "weekly",     "resets_at": "2026-01-19T12:00:00Z"}
          }
        }
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        let resolved = resp.resolvedWindows
        #expect(resolved.primary?.usedPercent == 32.0)
        #expect(resolved.secondary?.usedPercent == 12.5)
        #expect(resolved.primary?.remaining == 680)
    }

    @Test("UsageResponse decodes the flat primary/secondary shape too")
    func decodesFlatShape() throws {
        let json = Data("""
        {
          "primary":   {"used_percent": 80.0},
          "secondary": {"used_percent": 25.0}
        }
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        let resolved = resp.resolvedWindows
        #expect(resolved.primary?.usedPercent == 80.0)
        #expect(resolved.secondary?.usedPercent == 25.0)
    }

    @Test("UsageWindow decodes the alternate `usage_percent` key when `used_percent` is absent")
    func decodesAlternateUsagePercentKey() throws {
        let json = Data("""
        {"primary": {"usage_percent": 73.0}}
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        #expect(resp.primary?.usedPercent == 73.0)
    }

    @Test("UsageWindow derives percent from used/limit when no percent field is emitted")
    func derivesUsedPercentFromUsedAndLimit() throws {
        let json = Data("""
        {"primary": {"used": 250.0, "limit": 1000.0}}
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        #expect(resp.primary?.usedPercent == 25.0)
    }

    @Test("UsageWindow prefers used_percent over usage_percent over derived")
    func percentPreferenceOrder() throws {
        let json = Data("""
        {"primary": {"used_percent": 80.0, "usage_percent": 70.0, "used": 60.0, "limit": 100.0}}
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        #expect(resp.primary?.usedPercent == 80.0)
    }

    @Test("UsageWindow returns nil percent when neither percent field nor used/limit is present")
    func nilPercentWhenNoSource() throws {
        let json = Data("""
        {"primary": {"window": "5h_rolling"}}
        """.utf8)
        let resp = try backendJSONDecoder().decode(UsageResponse.self, from: json)
        #expect(resp.primary?.usedPercent == nil)
        #expect(resp.primary?.window == "5h_rolling")
    }

    @Test("Date decoder handles RFC 3339 with and without fractional seconds")
    func acceptsBothISOFormats() throws {
        let withFrac = Data("""
        {"primary": {"resets_at": "2026-01-15T12:00:00.123Z"}}
        """.utf8)
        let plain = Data("""
        {"primary": {"resets_at": "2026-01-15T12:00:00Z"}}
        """.utf8)

        let a = try backendJSONDecoder().decode(UsageResponse.self, from: withFrac)
        let b = try backendJSONDecoder().decode(UsageResponse.self, from: plain)
        #expect(a.primary?.resetsAt != nil)
        #expect(b.primary?.resetsAt != nil)
    }

    @Test("AccountsCheckResponse decodes plan tier")
    func decodesAccountsCheck() throws {
        let json = Data("""
        {
          "accounts": [
            {"account_id": "acct-1", "plan_type": "pro_5x", "is_deactivated": false, "role": "owner", "name": "Personal"}
          ],
          "account_ordering": ["acct-1"]
        }
        """.utf8)
        let resp = try backendJSONDecoder().decode(AccountsCheckResponse.self, from: json)
        #expect(resp.accounts?.first?.planType == "pro_5x")
        #expect(resp.accountOrdering == ["acct-1"])
    }

    @Test("TokenResponse decodes a standard OAuth refresh result")
    func decodesTokenResponse() throws {
        let json = Data("""
        {
          "access_token": "new-access",
          "refresh_token": "new-refresh-rotated",
          "id_token": "new-id",
          "token_type": "Bearer",
          "expires_in": 3600,
          "scope": "openid profile email offline_access"
        }
        """.utf8)
        let resp = try JSONDecoder().decode(TokenResponse.self, from: json)
        #expect(resp.accessToken == "new-access")
        #expect(resp.refreshToken == "new-refresh-rotated")
        #expect(resp.expiresIn == 3600)
    }

    @Test("AuthJSON round-trips through Codable")
    func authJSONRoundtrip() throws {
        let original = AuthJSON(
            tokens: AuthTokens(idToken: "i", accessToken: "a", refreshToken: "r", accountID: "acct"),
            lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try backendJSONDecoder().decode(AuthJSON.self, from: data)
        #expect(decoded.tokens?.refreshToken == "r")
        #expect(decoded.lastRefresh != nil)
    }
}
