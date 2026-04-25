import Testing
import Foundation
@testable import CodexSwitcher

@Suite("JWT decoder")
struct JWTTests {

    /// Build a synthetic JWT (no signature; we don't verify) so tests can probe the
    /// payload extraction without depending on a real OpenAI token.
    private static func makeJWT(payload: [String: Any]) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = "sig"
        return "\(base64URL(Data(header.utf8))).\(base64URL(payloadData)).\(signature)"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("Decodes chatgpt_user_id and chatgpt_account_id into a dedup key")
    func extractsDedupKey() throws {
        let token = Self.makeJWT(payload: [
            "exp": 1_900_000_000,
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "user-abc",
                "chatgpt_account_id": "acct-xyz",
                "chatgpt_plan_type": "pro_5x",
            ],
        ])

        let claims = try JWT.decode(token)

        #expect(claims.email == "user@example.com")
        #expect(claims.chatgptUserID == "user-abc")
        #expect(claims.chatgptAccountID == "acct-xyz")
        #expect(claims.chatgptPlanType == "pro_5x")
        #expect(claims.dedupKey == "user-abc::acct-xyz")
    }

    @Test("dedupKey is nil when either user or account claim is missing")
    func dedupKeyRequiresBothClaims() throws {
        let token = Self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": "only-user",
            ],
        ])
        let claims = try JWT.decode(token)
        #expect(claims.chatgptUserID == "only-user")
        #expect(claims.chatgptAccountID == nil)
        #expect(claims.dedupKey == nil)
    }

    @Test("Throws on a malformed token")
    func malformedToken() {
        #expect(throws: JWT.DecodeError.self) {
            _ = try JWT.decode("not-a-jwt")
        }
    }

    @Test("Tolerates JWTs without the 'https://api.openai.com/auth' wrapper")
    func missingAuthWrapperReturnsEmptyClaims() throws {
        let token = Self.makeJWT(payload: ["email": "u@example.com"])
        let claims = try JWT.decode(token)
        #expect(claims.dedupKey == nil)
        #expect(claims.email == "u@example.com")
    }

    @Test("isExpired honours skew window")
    func expirySkew() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Token expires 30 s from now → within 60s skew → treated as expired.
        let nearExpiry = JWT.Claims(
            exp: now.addingTimeInterval(30),
            email: nil, chatgptUserID: nil, chatgptAccountID: nil, chatgptPlanType: nil
        )
        #expect(JWT.isExpired(nearExpiry, now: now))

        // Token expires 5 minutes from now → not expired even with 60s skew.
        let safe = JWT.Claims(
            exp: now.addingTimeInterval(300),
            email: nil, chatgptUserID: nil, chatgptAccountID: nil, chatgptPlanType: nil
        )
        #expect(!JWT.isExpired(safe, now: now))

        // Already past exp → expired.
        let stale = JWT.Claims(
            exp: now.addingTimeInterval(-1),
            email: nil, chatgptUserID: nil, chatgptAccountID: nil, chatgptPlanType: nil
        )
        #expect(JWT.isExpired(stale, now: now))
    }

    @Test("base64URL handles missing padding")
    func base64UrlPadding() {
        // Three bytes encode to four base64 chars (no padding); we still expect a
        // round-trip when input lacks the trailing '='.
        let raw = #"{"x":1}"#
        let encoded = Self.base64URL(Data(raw.utf8))
        let decoded = JWT.base64URLDecode(encoded)
        #expect(decoded != nil)
        #expect(decoded.flatMap { String(data: $0, encoding: .utf8) } == raw)
    }
}
