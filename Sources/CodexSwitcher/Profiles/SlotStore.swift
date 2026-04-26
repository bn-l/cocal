import Foundation

/// Records which profile is *active* — i.e. whose `auth.json` we last installed at
/// the canonical Codex path. Tiny on purpose; PLAN.md §3 lists this as a separate
/// store from `ProfileStore` because the active-pointer lifetime is independent of
/// the profile catalog (you can delete the active profile without invalidating the
/// pointer until the next swap).
public final class SlotStore: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "com.bn-l.codex-switcher.SlotStore")

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public static func defaultLocation() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("codex-switcher/active-slot.json")
    }

    public func loadActiveID() -> String? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
            return payload.activeProfileID
        }
    }

    public func setActiveID(_ id: String?) throws {
        try queue.sync {
            let payload = Payload(activeProfileID: id, updatedAt: Date())
            let data = try JSONEncoder.iso.encode(payload)
            try data.write(to: url, options: [.atomic])
        }
    }

    private struct Payload: Codable {
        var activeProfileID: String?
        var updatedAt: Date
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
