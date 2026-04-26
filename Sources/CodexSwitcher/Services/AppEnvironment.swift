import Foundation
import Synchronization
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "AppEnvironment")

/// DI container for the app's persistent stores and the per-profile actor cache.
///
/// The environment is process-wide singleton state. Only `UsageMonitor` and the
/// (forthcoming) profile UI consume it; tests inject their own instance.
public final class AppEnvironment: @unchecked Sendable {
    public let profileStore: ProfileStore
    public let slotStore: SlotStore
    public let backend: BackendClient
    public let refresher: TokenRefresher
    public let switcher: Switcher
    public let resolver: AuthPathResolver

    private let actors = Mutex<[String: PerProfile]>([:])

    public init(
        profileStore: ProfileStore = ProfileStore(rootDirectory: ProfileStore.defaultLocation()),
        slotStore: SlotStore = SlotStore(url: SlotStore.defaultLocation()),
        backend: BackendClient = BackendClient(),
        refresher: TokenRefresher = TokenRefresher(),
        resolver: AuthPathResolver = AuthPathResolver()
    ) {
        self.profileStore = profileStore
        self.slotStore = slotStore
        self.backend = backend
        self.refresher = refresher
        self.resolver = resolver
        self.switcher = Switcher(profileStore: profileStore, slotStore: slotStore, resolver: resolver)
    }

    public func makeImporter() -> Importer {
        Importer(resolver: resolver, store: profileStore)
    }

    public static let shared = AppEnvironment()

    /// Returns the cached `PerProfile` actor for the given profile, creating one on
    /// first access. Per PLAN.md §2.3, exactly one actor instance per profile id is
    /// the foundation of refresh-token rotation safety.
    public func perProfile(for profile: Profile) -> PerProfile {
        actors.withLock { dict in
            if let existing = dict[profile.id] { return existing }
            let snapshotURL = profileStore.snapshotURL(for: profile.id)
            let actor = PerProfile(
                profileID: profile.id,
                snapshotURL: snapshotURL,
                backend: backend,
                refresher: refresher
            )
            dict[profile.id] = actor
            return actor
        }
    }

    /// Resolve `(profile, actor)` for the currently-active slot, or `nil` if no
    /// profile has been imported / activated yet.
    ///
    /// If `activeID` is set but no profile matches (i.e. the active profile was
    /// deleted but the slot pointer wasn't cleared), this returns `nil` rather
    /// than falling back to an arbitrary other profile. The live `auth.json`
    /// may still belong to the deleted account; using a different profile as
    /// the "outgoing" side of a swap would capture stale credentials into the
    /// wrong slot.
    public func activeProfileAndActor() -> (Profile, PerProfile)? {
        let profiles = profileStore.loadAll()
        let active: Profile?
        if let id = slotStore.loadActiveID() {
            active = profiles.first(where: { $0.id == id })
        } else {
            // No slot set yet — first import flow. Falling back to `profiles.first`
            // here is safe because no profile has ever been "active" so there's no
            // mismatched-credentials risk on the live auth path.
            active = profiles.first
        }
        guard let profile = active else { return nil }
        return (profile, perProfile(for: profile))
    }
}
