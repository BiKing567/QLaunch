import Foundation

/// Lightweight persistent entry representing an installed application in the catalog.
public struct CachedAppEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var bundleIdentifier: String
    public var installedAt: Date?
    public var lastUsedAt: Date?

    public init(
        id: String,
        name: String,
        path: String,
        bundleIdentifier: String,
        installedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.installedAt = installedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Stores and restores the cached application catalog to enable instantaneous
/// cold start with a complete layout snapshot before the background disk rescan finishes.
public enum AppCatalogCacheStore {
    public static func cacheFileURL(domain: String) -> URL {
        LaunchpadPreferenceStore.layoutSupportDirectory(domain: domain)
            .appendingPathComponent("catalog-cache.json")
    }

    public static func loadEntries(domain: String) -> [CachedAppEntry] {
        let url = cacheFileURL(domain: domain)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CachedAppEntry].self, from: data) else {
            return []
        }
        return entries
    }

    @discardableResult
    public static func saveEntries(_ entries: [CachedAppEntry], domain: String) -> Bool {
        let url = cacheFileURL(domain: domain)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func clear(domain: String) {
        let url = cacheFileURL(domain: domain)
        try? FileManager.default.removeItem(at: url)
    }
}
