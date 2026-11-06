import XCTest
@testable import QLaunchpadCore

final class CustomIconModelTests: XCTestCase {
    private var testDomain: String!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        testDomain = "com.qzrzz.qlaunchpad.test-\(UUID().uuidString)"
        tempDir = CustomIconManifestStore.customIconsDirectoryURL(domain: testDomain)
        try? FileManager.default.removeItem(at: tempDir)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testManifestSaveAndLoadRoundTrip() {
        var manifest = CustomIconManifest()
        manifest.icons["com.apple.Safari"] = CustomIconRecord(fileName: "safari.png", updatedAt: 123456)
        manifest.icons["com.google.Chrome"] = CustomIconRecord(fileName: "chrome.png", updatedAt: 654321)

        let saved = CustomIconManifestStore.saveManifest(manifest, domain: testDomain)
        XCTAssertTrue(saved)

        let loaded = CustomIconManifestStore.loadManifest(domain: testDomain)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.icons.count, 2)
        XCTAssertEqual(loaded.icons["com.apple.Safari"]?.fileName, "safari.png")
        XCTAssertEqual(loaded.icons["com.google.Chrome"]?.fileName, "chrome.png")
    }

    func testResolveMatchedKeyPriority() {
        var manifest = CustomIconManifest()
        let bundleID = "com.example.app"
        let specificAppID = "com.example.app#/Users/test/Applications/App.app"

        // 1. None matched
        XCTAssertNil(CustomIconManifestStore.resolveMatchedKey(appID: specificAppID, bundleIdentifier: bundleID, in: manifest))

        // 2. Only bundleID matched
        manifest.icons[bundleID] = CustomIconRecord(fileName: "bundle.png")
        XCTAssertEqual(
            CustomIconManifestStore.resolveMatchedKey(appID: specificAppID, bundleIdentifier: bundleID, in: manifest),
            bundleID
        )

        // 3. Specific appID override takes precedence over bundleID
        manifest.icons[specificAppID] = CustomIconRecord(fileName: "specific.png")
        XCTAssertEqual(
            CustomIconManifestStore.resolveMatchedKey(appID: specificAppID, bundleIdentifier: bundleID, in: manifest),
            specificAppID
        )
    }
}
