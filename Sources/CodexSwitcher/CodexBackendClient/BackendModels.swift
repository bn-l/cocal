import Foundation

/// Canonical constants from PLAN.md §1.1.1. Treated as load-bearing — every prior-art
/// Codex switcher uses the same values, and Codex itself rejects requests that omit
/// the `User-Agent`.
public enum BackendConstants {
    public static let userAgent = "codex-cli/1.0.0"
    public static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let oauthScopes = "openid profile email offline_access"
    public static let oauthExtraQuery = "id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=codex_cli_rs"

    /// Refresh tokens that are within this window of expiry are treated as already
    /// expired. Matches `auth_tokens_expire_within(auth_json, 60)` from the
    /// 170-carry/codex-tools derivative tool referenced in PLAN.md §1.3.
    public static let accessTokenExpirySkew: TimeInterval = 60

    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let accountCheckURL = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!
    public static let tokenRefreshURL = URL(string: "https://auth.openai.com/oauth/token")!
}

/// Response from `GET /backend-api/wham/usage`. Every field is `Optional` per the
/// M2 decision-gate strategy: we want to *survive* shape changes from OpenAI and
/// surface the drift as missing data rather than throw and brick the menu-bar.
///
/// Canonical shape (verified against `openai/codex`'s `RateLimitWindowSnapshot`
/// model and prior-art Codex switchers):
/// ```
/// {
///   "plan_type": "plus",
///   "rate_limit": {
///     "primary_window":   { "used_percent": …, "limit_window_seconds": …, "reset_after_seconds": …, "reset_at": <unix epoch> },
///     "secondary_window": { … }
///   }
/// }
/// ```
/// We also accept the legacy `rate_limits` (plural) / `primary`/`secondary` shape
/// some earlier prior-art docs described, plus the flat top-level `primary` /
/// `secondary` form, so a future shape revert doesn't brick the menu bar.
public struct UsageResponse: Codable, Sendable, Equatable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?

    /// Canonical shape: `rate_limit` (singular) wrapping `primary_window` /
    /// `secondary_window`.
    public let rateLimit: RateLimit?

    /// Legacy shape some earlier prior-art docs described: `rate_limits` (plural)
    /// wrapping bare `primary` / `secondary`.
    public let rateLimits: RateLimits?

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case rateLimit = "rate_limit"
        case rateLimits = "rate_limits"
    }

    /// Resolves whichever wrapping shape the server emitted to a flat `(primary, secondary)`.
    public var resolvedWindows: (primary: UsageWindow?, secondary: UsageWindow?) {
        if let r = rateLimit {
            return (r.primaryWindow ?? primary, r.secondaryWindow ?? secondary)
        }
        if let r = rateLimits {
            return (r.primary ?? primary, r.secondary ?? secondary)
        }
        return (primary, secondary)
    }
}

/// Canonical wrapper — `rate_limit.primary_window` / `rate_limit.secondary_window`.
public struct RateLimit: Codable, Sendable, Equatable {
    public let primaryWindow: UsageWindow?
    public let secondaryWindow: UsageWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

/// Legacy wrapper — kept for back-compat against earlier shape documentation.
public struct RateLimits: Codable, Sendable, Equatable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
}

public struct UsageWindow: Codable, Sendable, Equatable {
    /// 0–100. Decoded with three fallbacks (in order): `used_percent`,
    /// `usage_percent`, then derived from `used`/`limit`. The server has been
    /// observed emitting either of the percent keys; without the fallbacks the
    /// menu-bar gauge and auto-switch can read 0% on a real-but-unfamiliar shape.
    public let usedPercent: Double?

    /// Window label, e.g. `5h_rolling`, `weekly`. Used for diagnostics; we infer
    /// "primary vs secondary" from key position rather than this string.
    public let window: String?

    /// ISO-8601 timestamp when the rolling window resets.
    public let resetsAt: Date?

    public let limit: Double?
    public let used: Double?
    public let remaining: Double?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case window
        case resetsAt = "resets_at"
        case limit
        case used
        case remaining
    }

    private enum AlternateKeys: String, CodingKey {
        case usagePercent = "usage_percent"
        // Canonical key per openai/codex's `RateLimitWindowSnapshot` is `reset_at`
        // (no `s`). Earlier prior-art tools used `resets_at`. Accept both.
        case resetAt = "reset_at"
    }

    public init(usedPercent: Double?, window: String?, resetsAt: Date?, limit: Double?, used: Double?, remaining: Double?) {
        self.usedPercent = usedPercent
        self.window = window
        self.resetsAt = resetsAt
        self.limit = limit
        self.used = used
        self.remaining = remaining
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alt = try decoder.container(keyedBy: AlternateKeys.self)

        let primaryPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent)
        let alternatePercent = try alt.decodeIfPresent(Double.self, forKey: .usagePercent)
        let limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        let used = try c.decodeIfPresent(Double.self, forKey: .used)
        let derivedPercent: Double? = {
            guard let limit, limit > 0, let used else { return nil }
            return (used / limit) * 100
        }()

        self.usedPercent = primaryPercent ?? alternatePercent ?? derivedPercent
        self.window = try c.decodeIfPresent(String.self, forKey: .window)
        let resetsViaPrimaryKey = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        let resetsViaCanonicalKey = try alt.decodeIfPresent(Date.self, forKey: .resetAt)
        self.resetsAt = resetsViaPrimaryKey ?? resetsViaCanonicalKey
        self.limit = limit
        self.used = used
        self.remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
    }
}

/// Response from `GET /backend-api/accounts/check/v4-2023-04-27`. We only need the
/// plan tier and a friendly account label for the popover row; everything else is
/// captured loosely so we can audit the shape during the live-conformance test.
public struct AccountsCheckResponse: Codable, Sendable, Equatable {
    public let accounts: [Account]?
    public let accountOrdering: [String]?

    /// The single-account convenience field some endpoints return at the top level.
    public let account: Account?

    private enum CodingKeys: String, CodingKey {
        case accounts
        case accountOrdering = "account_ordering"
        case account
    }
}

public struct Account: Codable, Sendable, Equatable {
    public let accountID: String?
    public let planType: String?
    public let isDeactivated: Bool?
    public let role: String?
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case planType = "plan_type"
        case isDeactivated = "is_deactivated"
        case role
        case name
    }
}

/// Response from `POST /oauth/token`. The OAuth server emits a fresh access token,
/// a fresh ID token, and — critically — a *new single-use* refresh token. Persisting
/// the new `refreshToken` over the previous one is non-negotiable (PLAN.md §1.3).
public struct TokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let tokenType: String?
    public let expiresIn: Int?
    public let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

/// `auth.json` on disk — what Codex itself writes and what we snapshot per profile.
public struct AuthJSON: Codable, Sendable, Equatable {
    public var openAIApiKey: String?
    public var tokens: AuthTokens?
    public var lastRefresh: Date?

    private enum CodingKeys: String, CodingKey {
        case openAIApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    public init(openAIApiKey: String? = nil, tokens: AuthTokens?, lastRefresh: Date? = nil) {
        self.openAIApiKey = openAIApiKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }

    /// Freshness indicator used to decide which of two snapshots is newer.
    /// Prefers `lastRefresh` when available; falls back to the access token's
    /// `exp` claim. Returns `nil` when neither is available.
    public var freshnessMarker: Date? {
        if let lastRefresh { return lastRefresh }
        guard let token = tokens?.accessToken,
              let claims = try? JWT.decode(token) else { return nil }
        return claims.exp
    }
}

public struct AuthTokens: Codable, Sendable, Equatable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String?

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }

    public init(idToken: String, accessToken: String, refreshToken: String, accountID: String?) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
    }
}

/// Shared date formatters — `ISO8601DateFormatter` is expensive to construct,
/// and the custom date strategy closure runs for every `Date` field in every
/// decoded response.
// ISO8601DateFormatter is not Sendable, but these are effectively immutable
// after initialization — created once, read-only thereafter.
nonisolated(unsafe) private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let isoBasic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Decoder configured to parse the timestamp formats the Codex backend emits.
/// Several endpoints return RFC 3339 with fractional seconds; the OAuth path
/// uses Unix `expires_in` so it doesn't need date decoding.
public func backendJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            if let date = isoFractional.date(from: raw) { return date }
            if let date = isoBasic.date(from: raw) { return date }
        }
        if let epoch = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: epoch)
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO-8601 string or epoch number"
        )
    }
    return decoder
}
