import Foundation

/// Errors surfaced by the Codex HTTPS backend client and the OAuth token refresher.
public enum BackendError: Error, Sendable, Equatable {
    /// The HTTP status was non-2xx; carries the status code and any body string for diagnostics.
    case http(status: Int, body: String?)

    /// JSON decoding failed entirely (malformed body).
    case decoding(String)

    /// Profile snapshot could not be read or was malformed (no access token, etc.).
    case missingCredentials(String)

    /// One of the OAuth `RefreshTokenFailedReason` values from the upstream Codex source
    /// (PLAN.md §1.3). These are permanent failures — the profile must be re-imported.
    case refreshFailure(RefreshFailureReason)

    /// Network transport error (timeout, DNS failure, etc.).
    case transport(String)
}

/// Mirrors the upstream `RefreshTokenFailedReason` enum from
/// `codex-rs/protocol/src/auth.rs` so we can drive the profile warning state
/// from the same vocabulary the Codex CLI uses.
public enum RefreshFailureReason: String, Sendable, Equatable, CaseIterable {
    /// Server returned `refresh_token_expired` — the OAuth server's TTL has elapsed.
    case expired

    /// Server returned `refresh_token_reused` — single-use rotation was violated.
    /// This is the fatal failure mode the per-profile actor lock exists to prevent.
    case exhausted

    /// User logged out elsewhere or the token was administratively invalidated.
    case revoked

    /// Catch-all; may be transient and worth retrying once.
    case other
}
