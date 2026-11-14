import CoreFoundation
import Foundation

public struct LaunchpadPersistedLayout: Equatable, Sendable {
    public var itemOrder: [String]
    public var foldersData: Data
    public var hiddenIDs: [String]
    public var paginationType: LaunchpadLayoutPaginationType
    public var pagesData: Data?

    public init(
        itemOrder: [String],
        foldersData: Data,
        hiddenIDs: [String],
        paginationType: LaunchpadLayoutPaginationType = .continuous,
        pagesData: Data? = nil
    ) {
        self.itemOrder = itemOrder
        self.foldersData = foldersData
        self.hiddenIDs = hiddenIDs
        self.paginationType = paginationType
        self.pagesData = pagesData
    }
}

public enum LaunchpadPreferenceStore {
    public static let releaseDomain = "com.qzrzz.qlaunchpad"
    public static let developmentDomain = "com.qzrzz.qlaunchpad.dev"

    public static func encodeFolders(_ folders: [AppFolder]) throws -> Data {
        try LaunchpadPersistence.encodeFolders(folders)
    }

    public static func decodeFolders(_ data: Data) throws -> [AppFolder] {
        try LaunchpadPersistence.decodeFolders(data)
    }

    public static func encodePages(_ pages: [LaunchpadCustomPage]) throws -> Data {
        try LaunchpadPersistence.encodePages(pages)
    }

    public static func decodePages(_ data: Data) throws -> [LaunchpadCustomPage] {
        try LaunchpadPersistence.decodePages(data)
    }

    /// Missing key (`Data()`) is empty folders. Non-empty undecodable bytes throw.
    public static func decodePersistedFolders(_ data: Data) throws -> [AppFolder] {
        if data.isEmpty {
            return []
        }
        return try decodeFolders(data)
    }

    /// Synchronizes the domain, then copies the layout keys. Missing keys
    /// are empty arrays / empty `Data`.
    public static func readLayout(domain: String) -> LaunchpadPersistedLayout {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        let paginationRaw = copyString(key: LaunchpadPersistence.paginationTypeKey, applicationID: applicationID)
        let paginationType = paginationRaw.flatMap(LaunchpadLayoutPaginationType.init(rawValue:)) ?? .continuous
        let pagesData = copyData(key: LaunchpadPersistence.pagesKey, applicationID: applicationID)
        return LaunchpadPersistedLayout(
            itemOrder: copyStringArray(key: LaunchpadPersistence.itemOrderKey, applicationID: applicationID),
            foldersData: copyData(key: LaunchpadPersistence.foldersKey, applicationID: applicationID),
            hiddenIDs: copyStringArray(key: LaunchpadPersistence.hiddenAppsKey, applicationID: applicationID),
            paginationType: paginationType,
            pagesData: pagesData.isEmpty ? nil : pagesData
        )
    }

    /// Writes only keys that differ. Hidden is sorted before compare / set.
    /// Folders must be `CFData` (encoded `[AppFolder]` bytes), not a JSON string.
    /// Returns `false` when a dirty write's `CFPreferencesAppSynchronize` fails.
    @discardableResult
    public static func writeLayout(domain: String, _ layout: LaunchpadPersistedLayout) -> Bool {
        let applicationID = domain as CFString
        let next = LaunchpadPersistedLayout(
            itemOrder: layout.itemOrder,
            foldersData: layout.foldersData,
            hiddenIDs: layout.hiddenIDs.sorted(),
            paginationType: layout.paginationType,
            pagesData: layout.pagesData
        )
        let current = readLayout(domain: domain)
        var changed = false

        if next.itemOrder != current.itemOrder {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.itemOrderKey as CFString,
                next.itemOrder as CFArray,
                applicationID
            )
            changed = true
        }
        if next.foldersData != current.foldersData {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.foldersKey as CFString,
                next.foldersData as CFData,
                applicationID
            )
            changed = true
        }
        if next.hiddenIDs != current.hiddenIDs.sorted() {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.hiddenAppsKey as CFString,
                next.hiddenIDs as CFArray,
                applicationID
            )
            changed = true
        }
        if next.paginationType != current.paginationType {
            CFPreferencesSetAppValue(
                LaunchpadPersistence.paginationTypeKey as CFString,
                next.paginationType.rawValue as CFString,
                applicationID
            )
            changed = true
        }
        if next.pagesData != current.pagesData {
            if let pagesData = next.pagesData {
                CFPreferencesSetAppValue(
                    LaunchpadPersistence.pagesKey as CFString,
                    pagesData as CFData,
                    applicationID
                )
            } else {
                CFPreferencesSetAppValue(
                    LaunchpadPersistence.pagesKey as CFString,
                    nil,
                    applicationID
                )
            }
            changed = true
        }
        if changed {
            guard CFPreferencesAppSynchronize(applicationID) else {
                return false
            }
        }
        writeThroughIfCurrentDomain(domain, next)
        return true
    }

    public static func persistFolders(domain: String, _ folders: [AppFolder]) {
        guard let foldersData = try? encodeFolders(folders) else { return }
        var layout = readLayout(domain: domain)
        layout.foldersData = foldersData
        writeLayout(domain: domain, layout)
    }

    public static func persistItemOrder(domain: String, _ order: [String]) {
        var layout = readLayout(domain: domain)
        layout.itemOrder = order
        writeLayout(domain: domain, layout)
    }

    public static func persistHiddenApps(domain: String, _ hidden: Set<String>) {
        var layout = readLayout(domain: domain)
        layout.hiddenIDs = hidden.sorted()
        writeLayout(domain: domain, layout)
    }

    public static func readString(domain: String, key: String) -> String? {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return nil
        }
        return value as? String
    }

    public static func readStringArray(domain: String, key: String) -> [String] {
        let applicationID = domain as CFString
        CFPreferencesAppSynchronize(applicationID)
        return copyStringArray(key: key, applicationID: applicationID)
    }

    public static func writeThroughToStandardDefaults(_ layout: LaunchpadPersistedLayout) {
        let hidden = layout.hiddenIDs.sorted()
        UserDefaults.standard.set(layout.itemOrder, forKey: LaunchpadPersistence.itemOrderKey)
        UserDefaults.standard.set(layout.foldersData, forKey: LaunchpadPersistence.foldersKey)
        UserDefaults.standard.set(hidden, forKey: LaunchpadPersistence.hiddenAppsKey)
        UserDefaults.standard.set(layout.paginationType.rawValue, forKey: LaunchpadPersistence.paginationTypeKey)
        if let pagesData = layout.pagesData {
            UserDefaults.standard.set(pagesData, forKey: LaunchpadPersistence.pagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LaunchpadPersistence.pagesKey)
        }
    }

    public static func layoutBackupFileURL(domain: String) -> URL {
        layoutSupportDirectory(domain: domain)
            .appendingPathComponent("layout.backup.json")
    }

    public static func layoutWorkingFileURL(domain: String) -> URL {
        layoutSupportDirectory(domain: domain)
            .appendingPathComponent("qlaunch-layout.json")
    }

    public static func layoutSupportDirectory(domain: String) -> URL {
        let folderName = domain == developmentDomain ? "QLaunch Dev" : "QLaunch"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func writeLayoutBackup(domain: String, document: LaunchpadLayoutDocument) throws {
        let data = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(document)
        let url = layoutBackupFileURL(domain: domain)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func writeThroughIfCurrentDomain(_ domain: String, _ layout: LaunchpadPersistedLayout) {
        let currentDomain = Bundle.main.bundleIdentifier
            ?? (kCFPreferencesCurrentApplication as String)
        guard domain == currentDomain else { return }
        writeThroughToStandardDefaults(layout)
    }

    private static func copyStringArray(key: String, applicationID: CFString) -> [String] {
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return []
        }
        if let strings = value as? [String] {
            return strings
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    private static func copyData(key: String, applicationID: CFString) -> Data {
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return Data()
        }
        if let data = value as? Data {
            return data
        }
        return Data()
    }

    private static func copyString(key: String, applicationID: CFString) -> String? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, applicationID) else {
            return nil
        }
        return value as? String
    }
}
