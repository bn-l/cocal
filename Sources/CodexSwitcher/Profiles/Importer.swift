import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Importer")

/// PLAN.md §2.3 "Adding a profile — single import flow, no in-app login".
///
/// We never run an OAuth flow inside the app. The user runs `codex login` (or signs
/// in via Codex.app) the normal way; we observe the resulting `auth.json` on disk
/// and dedup it against profiles we've already imported.
public struct Importer: Sendable {
    private let resolver: AuthPathResolver
    private let store: ProfileStore

    public init(resolver: AuthPathResolver = AuthPathResolver(), store: ProfileStore) {
        self.resolver = resolver
        self.store = store
    }

    public enum ImportError: Error, Equatable {
        case noLiveAuth
        case malformed(String)
        case missingDedupClaims
    }

    public enum Outcome: Equatable {
        /// Brand-new profile created from the live auth.json.
        case imported(Profile)

        /// The dedup key matched an existing profile — caller should surface
        /// "No new credentials found. Run `codex login` for a different ChatGPT
        /// account and Import again." (PLAN.md §2.3 step 5.)
        case duplicate(existing: Profile)

        /// Existing profile re-imported with fresher tokens than the stored snapshot —
        /// the per-profile actor wrote the newer snapshot.
        case refreshed(existing: Profile)
    }

    /// Read the live auth.json, decide if it's new vs. duplicate vs. fresher-than-stored,
    /// and act accordingly.
    public func runImport(label: String? = nil) throws -> (Outcome, AuthJSON) {
        guard let liveURL = resolver.canonicalReadPath() else {
            throw ImportError.noLiveAuth
        }
        let auth: AuthJSON
        do {
            auth = try Snapshotter.read(liveURL)
        } catch {
            throw ImportError.malformed(String(describing: error))
        }
        guard let tokens = auth.tokens else {
            throw ImportError.malformed("auth.json has no tokens object")
        }

        let claims: JWT.Claims
        do {
            claims = try JWT.decode(tokens.idToken)
        } catch {
            throw ImportError.malformed("id_token: \(error)")
        }
        guard let dedupKey = claims.dedupKey else {
            throw ImportError.missingDedupClaims
        }

        if let existing = store.loadByDedupKey(dedupKey) {
            // Compare the live snapshot's freshness against what's stored. If the
            // live file has a newer `last_refresh` (or fresher access-token expiry),
            // overwrite the stored snapshot and surface as `.refreshed` so the UI
            // can tell the user something useful instead of "duplicate".
            let storedURL = store.snapshotURL(for: existing.id)
            let stored = try? Snapshotter.read(storedURL)
            if shouldPrefer(incoming: auth, over: stored) {
                try Snapshotter.write(auth, to: storedURL)
                return (.refreshed(existing: existing), auth)
            }
            return (.duplicate(existing: existing), auth)
        }

        let resolvedLabel = label?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? claims.email
            ?? "ChatGPT account"
        let profile = Profile(
            label: resolvedLabel,
            dedupKey: dedupKey,
            planType: claims.chatgptPlanType
        )
        try store.insert(profile, snapshot: auth)
        logger.info("Imported new profile=\(profile.id, privacy: .public) dedup=\(dedupKey, privacy: .private(mask: .hash))")
        return (.imported(profile), auth)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private func shouldPrefer(incoming: AuthJSON, over existing: AuthJSON?) -> Bool {
    guard let existing else { return true }
    let im = freshnessMarker(for: incoming)
    let em = freshnessMarker(for: existing)
    switch (im, em) {
    case let (i?, e?): return i > e
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return false  // No marker either way — leave stored alone (treat as duplicate).
    }
}

private func freshnessMarker(for auth: AuthJSON) -> Date? {
    if let lastRefresh = auth.lastRefresh { return lastRefresh }
    guard let token = auth.tokens?.accessToken,
          let claims = try? JWT.decode(token) else { return nil }
    return claims.exp
}
