import Testing
import Foundation
@testable import CodexSwitcher

@Suite("Backend Codable models")
struct BackendModelsTests {

    @Test("UsageResponse decodes the nested rate_limits shape")
    func decodesNestedRateLimits() throws {
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
