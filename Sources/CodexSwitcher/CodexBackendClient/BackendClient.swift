import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "BackendClient")

/// HTTPS client for the ChatGPT backend usage and account-info endpoints. Stateless
/// over its inputs — every request takes the credentials it needs explicitly so the
/// client can be reused across profiles without sharing state.
///
/// Designed as a `final class` (not actor) because `URLSession` is already thread-safe
/// and the only mutable state we'd want to serialize (in-flight coalescing, snapshot
/// caching) lives on the per-profile actor instead — see PLAN.md §2.3 "Per-profile
/// write serialization".
public final class BackendClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `GET /backend-api/wham/usage` with the canonical headers from §1.1.1.
    public func usage(accessToken: String, accountID: String) async throws -> UsageResponse {
        try await get(BackendConstants.usageURL,
                      accessToken: accessToken,
                      accountID: accountID,
                      decode: UsageResponse.self)
    }

    /// `GET /backend-api/accounts/check/v4-2023-04-27` for plan tier and friendly name.
    public func accountsCheck(accessToken: String, accountID: String) async throws -> AccountsCheckResponse {
        try await get(BackendConstants.accountCheckURL,
                      accessToken: accessToken,
                      accountID: accountID,
                      decode: AccountsCheckResponse.self)
    }

    private func get<T: Decodable>(
        _ url: URL,
        accessToken: String,
        accountID: String,
        decode type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(BackendConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Transport error for \(url, privacy: .public): \(String(describing: error), privacy: .public)")
            throw BackendError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("Non-HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            logger.warning("HTTP \(http.statusCode) from \(url, privacy: .public)")
            throw BackendError.http(status: http.statusCode, body: body)
        }

        do {
            return try backendJSONDecoder().decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            logger.error("Decoding failure for \(url, privacy: .public): \(String(describing: error), privacy: .public). Body: \(body, privacy: .private(mask: .hash))")
            throw BackendError.decoding(String(describing: error))
        }
    }
}
