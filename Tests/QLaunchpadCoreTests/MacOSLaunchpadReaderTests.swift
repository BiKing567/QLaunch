import XCTest
@testable import QLaunchpadCore

final class MacOSLaunchpadReaderTests: XCTestCase {
    func testNonExistentDatabaseThrowsNotFound() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_launchpad_db_\(UUID().uuidString).db")
        XCTAssertThrowsError(try MacOSLaunchpadReader.readLayoutDocument(from: fakeURL)) { error in
            XCTAssertEqual(error as? MacOSLaunchpadError, .databaseNotFound)
        }
    }

    func testSystemDatabaseIfAvailableParsesValidDocument() throws {
        guard let dbURL = MacOSLaunchpadReader.defaultDatabaseURL() else {
            // If running in an environment without macOS Launchpad DB, skip gracefully
            return
        }

        do {
            let document = try MacOSLaunchpadReader.readLayoutDocument(from: dbURL)
            XCTAssertEqual(document.kind, LaunchpadLayoutKind.current)
            XCTAssertEqual(document.schemaVersion, LaunchpadLayoutKind.schemaVersion)
            XCTAssertFalse(document.items.isEmpty)
            XCTAssertNoThrow(try LaunchpadLayoutImporter.validate(document))
        } catch MacOSLaunchpadError.cannotOpenDatabase(23) {
            // Permission denied in restricted or sandboxed testing environment
            return
        }
    }

    func testAppFolderDefaultName() {
        let folder = AppFolder(appIDs: ["test"])
        XCTAssertEqual(folder.name, AppFolder.defaultName)
        XCTAssertEqual(AppFolder.defaultName, "文件夹")
    }
}
