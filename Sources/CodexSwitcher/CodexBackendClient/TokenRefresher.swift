import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "TokenRefresher")

/// Issues OAuth refresh requests against `auth.openai.com/oauth/token` using the
/// canonical `client_id` from PLAN.md §1.1.1.
///
/// Crucially, this type is **stateless and unaware of where the refresh token lives**.
/// The caller (`PerProfile`) owns the snapshot file and is responsible for persisting
/// the rotated refresh token immediately after a successful response. Splitting the
/// network call from the persistence step is what lets the per-profile actor enforce
/// single-use rotation — without it, a stale refresh token can be reused and brick
/// the profile (`RefreshTokenFailedReason::Exhausted`).
public final class TokenRefresher: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func refresh(refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: BackendConstants.tokenRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(BackendConstants.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "client_id": BackendConstants.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": BackendConstants.oauthScopes,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Transport error refreshing token: \(String(describing: error), privacy: .public)")
            throw BackendError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from token endpoint")
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw BackendError.decoding(String(describing: error))
            }
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        let reason = Self.classifyFailure(status: http.statusCode, body: bodyString)
        logger.warning("Refresh failed: status=\(http.statusCode) reason=\(reason.rawValue, privacy: .public)")
        throw BackendError.refreshFailure(reason)
    }

    /// Maps an OAuth error response onto the `RefreshTokenFailedReason` enum from
    /// `codex-rs/protocol/src/auth.rs` (PLAN.md §1.3). The OAuth server returns a
    /// JSON body shaped like `{"error": "refresh_token_expired"}`.
    static func classifyFailure(status _: Int, body: String) -> RefreshFailureReason {
        let lowered = body.lowercased()
        if lowered.contains("refresh_token_expired") { return .expired }
        if lowered.contains("refresh_token_reused") { return .exhausted }
        if lowered.contains("invalid_grant") {
            // `invalid_grant` without a more specific reason commonly means the user
            // logged out or the token was revoked.
            return .revoked
        }
        return .other
    }
}
