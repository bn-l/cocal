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
