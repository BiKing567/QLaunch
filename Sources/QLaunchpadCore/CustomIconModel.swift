import Foundation

public struct CustomIconRecord: Codable, Equatable, Sendable {
    public var fileName: String
    public var updatedAt: Double

    public init(fileName: String, updatedAt: Double = Date().timeIntervalSince1970) {
        self.fileName = fileName
        self.updatedAt = updatedAt
    }
}

public struct CustomIconManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Double
    /// Key can be either a bundleIdentifier or an appID (for specific path overrides)
    public var icons: [String: CustomIconRecord]

    public init(
        schemaVersion: Int = 1,
        updatedAt: Double = Date().timeIntervalSince1970,
        icons: [String: CustomIconRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.icons = icons
    }
}

public enum CustomIconManifestStore {
    public static func customIconsDirectoryURL(domain: String) -> URL {
        LaunchpadPreferenceStore.layoutSupportDirectory(domain: domain)
            .appendingPathComponent("CustomIcons", isDirectory: true)
    }

    public static func imagesDirectoryURL(domain: String) -> URL {
        customIconsDirectoryURL(domain: domain)
            .appendingPathComponent("images", isDirectory: true)
    }

    public static func manifestFileURL(domain: String) -> URL {
        customIconsDirectoryURL(domain: domain)
            .appendingPathComponent("manifest.json")
    }

    public static func loadManifest(domain: String) -> CustomIconManifest {
        let url = manifestFileURL(domain: domain)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CustomIconManifest.self, from: data) else {
            return CustomIconManifest()
        }
        return manifest
    }

    @discardableResult
    public static func saveManifest(_ manifest: CustomIconManifest, domain: String) -> Bool {
        let url = manifestFileURL(domain: domain)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Resolves the matching custom icon key with priority:
    /// 1. Specific appID override
    /// 2. General bundleIdentifier
    public static func resolveMatchedKey(
        appID: String,
        bundleIdentifier: String,
        in manifest: CustomIconManifest
    ) -> String? {
        if manifest.icons[appID] != nil {
            return appID
        }
        if manifest.icons[bundleIdentifier] != nil {
            return bundleIdentifier
        }
        return nil
    }
}
