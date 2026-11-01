import Foundation
@testable import QLaunchpadCore
import XCTest

final class AppCatalogCacheStoreTests: XCTestCase {
    private let testDomain = "com.qzrzz.qlaunchpad.test.\(UUID().uuidString)"

    override func tearDown() {
        AppCatalogCacheStore.clear(domain: testDomain)
        super.tearDown()
    }

    func testSaveAndLoadEntriesRoundTrip() {
        let entries = [
            CachedAppEntry(
                id: "com.apple.finder",
                name: "访达",
                path: "/System/Library/CoreServices/Finder.app",
                bundleIdentifier: "com.apple.finder",
                installedAt: Date(timeIntervalSince1970: 1700000000),
                lastUsedAt: Date(timeIntervalSince1970: 1700001000)
            ),
            CachedAppEntry(
                id: "com.apple.TextEdit",
                name: "文本编辑",
                path: "/System/Applications/TextEdit.app",
                bundleIdentifier: "com.apple.TextEdit"
            )
        ]

        let saved = AppCatalogCacheStore.saveEntries(entries, domain: testDomain)
        XCTAssertTrue(saved)

        let loaded = AppCatalogCacheStore.loadEntries(domain: testDomain)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "com.apple.finder")
        XCTAssertEqual(loaded[0].name, "访达")
        XCTAssertEqual(loaded[0].path, "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(loaded[1].id, "com.apple.TextEdit")
        XCTAssertEqual(loaded[1].name, "文本编辑")
    }

    func testLoadFromNonExistentFileReturnsEmpty() {
        let empty = AppCatalogCacheStore.loadEntries(domain: "non.existent.domain.\(UUID().uuidString)")
        XCTAssertTrue(empty.isEmpty)
    }

    func testCorruptedFileReturnsEmpty() throws {
        let url = AppCatalogCacheStore.cacheFileURL(domain: testDomain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "corrupted json payload".write(to: url, atomically: true, encoding: .utf8)

        let loaded = AppCatalogCacheStore.loadEntries(domain: testDomain)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testClearRemovesFile() {
        let entries = [
            CachedAppEntry(id: "app1", name: "App 1", path: "/Applications/App1.app", bundleIdentifier: "app1")
        ]
        AppCatalogCacheStore.saveEntries(entries, domain: testDomain)
        XCTAssertFalse(AppCatalogCacheStore.loadEntries(domain: testDomain).isEmpty)

        AppCatalogCacheStore.clear(domain: testDomain)
        XCTAssertTrue(AppCatalogCacheStore.loadEntries(domain: testDomain).isEmpty)
    }
}
