import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Switcher")

/// Orchestrates the A → B swap (PLAN.md §2.3 "Switch flow"):
///
///   1. **Capture A's freshness first.** Read live `auth.json` and stash it back
///      into profile A's snapshot, absorbing any refresh that happened during
///      the active session.
///   2. Write profile B's snapshot to the canonical auth path atomically.
///   3. If Keychain mirroring is enabled, update the `"Codex Auth"` entry
///      (dedup-key gated).
///   4. Set the slot store, leaving the popover to flip to needs-restart state.
///
/// Cross-profile coordination uses **ordered acquisition** to prevent deadlock:
/// always lock the outgoing actor before the incoming actor.
public actor Switcher {
    private let profileStore: ProfileStore
    private let slotStore: SlotStore
    private let desktopAuth: DesktopAuthService
    private let resolver: AuthPathResolver

    public init(
        profileStore: ProfileStore,
        slotStore: SlotStore,
        desktopAuth: DesktopAuthService = DesktopAuthService(),
        resolver: AuthPathResolver = AuthPathResolver()
    ) {
        self.profileStore = profileStore
        self.slotStore = slotStore
        self.desktopAuth = desktopAuth
        self.resolver = resolver
    }

    public enum SwitchError: Error, Equatable {
        case sameProfile
        case unknownProfile(String)
        case noActiveLiveAuth
    }

    /// Perform the swap from the currently active profile (if any) to `incoming`.
    /// Returns the URL we wrote `auth.json` to so the caller can plumb it into the
    /// "needs restart" affordance.
    @discardableResult
    public func switchTo(
        incoming incomingProfile: Profile,
        outgoingActor: PerProfile?,
        incomingActor: PerProfile
    ) async throws -> URL {
        // Step 1 — capture A's freshness if there's an active profile.
        if let outgoingActor {
            if outgoingActor === incomingActor {
                throw SwitchError.sameProfile
            }
            if let liveURL = resolver.canonicalReadPath() {
                do {
                    try await outgoingActor.captureLive(from: liveURL)
                } catch {
                    logger.warning("Outgoing capture-live failed (continuing): \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Step 2 — write the incoming profile's snapshot to the canonical path.
        // The per-profile actor owns the snapshot file; we read it under the actor's
        // queue and pass the in-memory bundle to `desktopAuth` for the canonical write.
        let bundle = try await incomingActor.readSnapshot()
        let outgoingDedupKey: String? = await {
            guard let actor = outgoingActor else { return nil }
            return try? await Snapshotter.dedupKey(for: actor.readSnapshot())
        }()

        let target = try desktopAuth.install(
            bundle,
            outgoingDedupKey: outgoingDedupKey,
            incomingDedupKey: incomingProfile.dedupKey
        )

        // Step 4 — slot pointer.
        try slotStore.setActiveID(incomingProfile.id)
        logger.info("Activated profile=\(incomingProfile.id, privacy: .public) at=\(target.path, privacy: .public)")
        return target
    }
}
