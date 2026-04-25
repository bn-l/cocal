import Foundation

/// Lightweight JWT claim extractor. We never *verify* signatures here — these are our
/// own user's tokens being decoded for local dedup and expiry checks. No security
/// boundary to enforce on the client side.
///
/// The shape of the claims we care about (PLAN.md §1.3, §2.3):
///
///   {
///     "exp": 1730000000,
///     "email": "user@example.com",
///     "https://api.openai.com/auth": {
///       "chatgpt_user_id": "user-…",
///       "chatgpt_account_id": "acct-…",
///       "chatgpt_plan_type": "pro_5x"
///     }
///   }
public enum JWT {
    /// All the claims we actively consume. Anything else stays in `extra` for future use.
    public struct Claims: Sendable, Equatable {
        public let exp: Date?
        public let email: String?
        public let chatgptUserID: String?
        public let chatgptAccountID: String?
        public let chatgptPlanType: String?

        /// `chatgpt_user_id::chatgpt_account_id` — the dedup key for the import flow
        /// (PLAN.md §2.3). `nil` if either component is missing.
        public var dedupKey: String? {
            guard let user = chatgptUserID, let account = chatgptAccountID else { return nil }
            return "\(user)::\(account)"
        }
    }

    public enum DecodeError: Error, Equatable {
        case malformed(String)
    }

    public static func decode(_ token: String) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw DecodeError.malformed("JWT must have at least 2 segments separated by '.'")
        }
        let payload = String(parts[1])
        guard let data = base64URLDecode(payload) else {
            throw DecodeError.malformed("payload segment is not valid base64url")
        }
        guard let raw = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw DecodeError.malformed("payload is not a JSON object")
        }

        let exp: Date? = (raw["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (raw["exp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let email = raw["email"] as? String

        let authClaim = raw["https://api.openai.com/auth"] as? [String: Any]
        let userID = authClaim?["chatgpt_user_id"] as? String
        let accountID = authClaim?["chatgpt_account_id"] as? String
        let planType = authClaim?["chatgpt_plan_type"] as? String

        return Claims(
            exp: exp,
            email: email,
            chatgptUserID: userID,
            chatgptAccountID: accountID,
            chatgptPlanType: planType
        )
    }

    /// Returns `true` when the access token has expired or is within `skew` seconds
    /// of expiring. Matches PLAN.md §1.1.1's 60-second skew window.
    public static func isExpired(_ claims: Claims, now: Date, skew: TimeInterval = BackendConstants.accessTokenExpirySkew) -> Bool {
        guard let exp = claims.exp else { return true }
        return exp.addingTimeInterval(-skew) <= now
    }

    /// JWTs use base64url (URL-safe, no padding). `Data(base64Encoded:)` requires
    /// the standard alphabet plus padding, so translate before decoding.
    static func base64URLDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: s)
    }
}
