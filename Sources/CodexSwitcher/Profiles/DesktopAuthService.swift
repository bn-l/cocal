import Foundation
import OSLog
#if canImport(Security)
import Security
#endif

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "DesktopAuth")

/// Writes an `auth.json` to the canonical Codex path so a freshly-launched `codex`
/// CLI / Codex.app will pick it up. PLAN.md §2.3 — write to **only** the
/// highest-precedence existing path, never fan out.
///
/// Optional Keychain mirror under service `"Codex Auth"` for Codex.app desktop
/// compat. The mirror is gated on dedup-key matching so we never overwrite an
/// unrelated account that some third party (e.g. a fresh login from Codex.app
/// itself) put there.
public struct DesktopAuthService: Sendable {
    public let resolver: AuthPathResolver
    public let keychainEnabled: Bool

    public init(resolver: AuthPathResolver = AuthPathResolver(), keychainEnabled: Bool = true) {
        self.resolver = resolver
        self.keychainEnabled = keychainEnabled
    }

    /// Install `auth` at the canonical Codex path. Returns the URL we wrote to.
    /// Per PLAN.md §2.3 the mirror is best-effort — failure to update the Keychain
    /// does not roll back the file write but is surfaced via the throwing return.
    @discardableResult
    public func install(
        _ auth: AuthJSON,
        outgoingDedupKey: String?,
        incomingDedupKey: String
    ) throws -> URL {
        let target = resolver.canonicalWritePath()
        let backupURL = target.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: target.path) {
            // Best-effort backup of whatever was there before. Don't fail the install
            // if backup fails — the atomic rename below is still safe.
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: target, to: backupURL)
        }
        try Snapshotter.write(auth, to: target)

        #if canImport(Security)
        if keychainEnabled {
            do {
                try mirrorToKeychain(auth, outgoingDedupKey: outgoingDedupKey, incomingDedupKey: incomingDedupKey)
            } catch {
                logger.warning("Keychain mirror failed (file write succeeded): \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        #endif
        return target
    }

    #if canImport(Security)
    /// Generic-password entry under service `"Codex Auth"`. Codex.app reads from
    /// here on launch, so updating it lets a freshly-spawned Codex.app see the
    /// swap without us touching its private storage format.
    ///
    /// Gating: we only overwrite an existing entry when its dedup key matches
    /// `outgoingDedupKey` (the profile we're switching *out of*) or the entry
    /// is absent. Any other case means an unmanaged third party owns it.
    private func mirrorToKeychain(
        _ auth: AuthJSON,
        outgoingDedupKey: String?,
        incomingDedupKey: String
    ) throws {
        let service = "Codex Auth"
        let account = "codex"

        let payload = try JSONEncoder().encode(auth)

        // Look up any existing entry first.
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            // Does the existing entry's dedup key match the profile we're swapping out
            // (or the one we're swapping in — idempotent install)?
            let existingKey = (try? Snapshotter.dedupKey(for: backendJSONDecoder().decode(AuthJSON.self, from: data)))
            let allowed = existingKey == outgoingDedupKey
                || existingKey == incomingDedupKey
                || existingKey == nil
            guard allowed else {
                throw KeychainError.thirdPartyEntry(existingKey: existingKey ?? "<unknown>")
            }
            let attrs: [CFString: Any] = [kSecValueData: payload]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.osStatus(updateStatus)
            }
        } else if status == errSecItemNotFound {
            let add: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: payload,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else {
            throw KeychainError.osStatus(status)
        }
    }
    #endif
}

public enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case thirdPartyEntry(existingKey: String)
}
