import XCTest
@testable import QLaunchpadCore

final class LaunchpadCustomPageReconcilerTests: XCTestCase {
    func testChunkItemsSplitsByCapacity() {
        let items = ["A", "B", "C", "D", "E"]
        let pages = LaunchpadCustomPageReconciler.chunkItems(items, capacity: 2)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].itemIDs, ["A", "B"])
        XCTAssertEqual(pages[1].itemIDs, ["C", "D"])
        XCTAssertEqual(pages[2].itemIDs, ["E"])
    }

    func testReconcileEmptyPagesChunksItems() {
        let items = ["1", "2", "3", "4"]
        let reconciled = LaunchpadCustomPageReconciler.reconcile(
            pages: [],
            rootItemIDs: items,
            capacity: 3
        )
        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(reconciled[0].itemIDs, ["1", "2", "3"])
        XCTAssertEqual(reconciled[1].itemIDs, ["4"])
    }

    func testReconcilePreservesPageAssignmentsWithGaps() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B"])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: ["C"])
        let p2 = LaunchpadCustomPage(id: "p2", itemIDs: ["D", "E"])

        let reconciled = LaunchpadCustomPageReconciler.reconcile(
            pages: [p0, p1, p2],
            rootItemIDs: ["A", "B", "C", "D", "E"],
            capacity: 4
        )
        XCTAssertEqual(reconciled.count, 3)
        XCTAssertEqual(reconciled[0].id, "p0")
        XCTAssertEqual(reconciled[0].itemIDs, ["A", "B"])
        XCTAssertEqual(reconciled[1].id, "p1")
        XCTAssertEqual(reconciled[1].itemIDs, ["C"])
        XCTAssertEqual(reconciled[2].id, "p2")
        XCTAssertEqual(reconciled[2].itemIDs, ["D", "E"])
    }

    func testReconcileRemovesObsoleteItemsLeavingGroupsIntact() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B", "Obsolete1"])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: ["Obsolete2", "C"])

        let reconciled = LaunchpadCustomPageReconciler.reconcile(
            pages: [p0, p1],
            rootItemIDs: ["A", "B", "C"],
            capacity: 5
        )
        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(reconciled[0].itemIDs, ["A", "B"])
        XCTAssertEqual(reconciled[1].itemIDs, ["C"])
    }

    func testReconcileAppendsNewItemsToLastPageOrExpands() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B"])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: ["C"])

        // Capacity is 2. p1 currently has 1 item, so it can accept 1 new item before expanding.
        let reconciled = LaunchpadCustomPageReconciler.reconcile(
            pages: [p0, p1],
            rootItemIDs: ["A", "B", "C", "New1", "New2"],
            capacity: 2
        )
        XCTAssertEqual(reconciled.count, 3)
        XCTAssertEqual(reconciled[0].itemIDs, ["A", "B"])
        XCTAssertEqual(reconciled[1].itemIDs, ["C", "New1"])
        XCTAssertEqual(reconciled[2].itemIDs, ["New2"])
    }

    func testReconcileSplitsPagesWhenCapacityDecreases() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B", "C", "D"])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: ["E", "F"])

        // Capacity reduced from 4 to 2
        let reconciled = LaunchpadCustomPageReconciler.reconcile(
            pages: [p0, p1],
            rootItemIDs: ["A", "B", "C", "D", "E", "F"],
            capacity: 2
        )
        XCTAssertEqual(reconciled.count, 3)
        XCTAssertEqual(reconciled[0].id, "p0")
        XCTAssertEqual(reconciled[0].itemIDs, ["A", "B"])
        XCTAssertEqual(reconciled[1].itemIDs, ["C", "D"])
        XCTAssertEqual(reconciled[2].id, "p1")
        XCTAssertEqual(reconciled[2].itemIDs, ["E", "F"])
    }

    func testCascadeOverflowPushesToNextPages() {
        var pages = [
            LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B", "C"]), // capacity is 2 -> overflows C
            LaunchpadCustomPage(id: "p1", itemIDs: ["D", "E"]),       // capacity is 2 -> receives C, overflows E
            LaunchpadCustomPage(id: "p2", itemIDs: ["F"])             // receives E -> becomes [E, F]
        ]
        LaunchpadCustomPageReconciler.cascadeOverflow(pages: &pages, startingAt: 0, capacity: 2)

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].itemIDs, ["A", "B"])
        XCTAssertEqual(pages[1].itemIDs, ["C", "D"])
        XCTAssertEqual(pages[2].itemIDs, ["E", "F"])
    }

    func testCascadeOverflowCreatesNewPageWhenLastPageFull() {
        var pages = [
            LaunchpadCustomPage(id: "p0", itemIDs: ["A", "B", "C"]),
            LaunchpadCustomPage(id: "p1", itemIDs: ["D", "E"])
        ]
        LaunchpadCustomPageReconciler.cascadeOverflow(pages: &pages, startingAt: 0, capacity: 2)

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].itemIDs, ["A", "B"])
        XCTAssertEqual(pages[1].itemIDs, ["C", "D"])
        XCTAssertEqual(pages[2].itemIDs, ["E"])
    }

    func testPruneEmptyPagesRemovesEmptyAndPreservesActivePage() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: ["A"])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: [])
        let p2 = LaunchpadCustomPage(id: "p2", itemIDs: ["B"])

        let (pruned, activeIndex) = LaunchpadCustomPageReconciler.pruneEmptyPages(
            pages: [p0, p1, p2],
            activePageID: "p2"
        )
        XCTAssertEqual(pruned.count, 2)
        XCTAssertEqual(pruned.map(\.id), ["p0", "p2"])
        XCTAssertEqual(activeIndex, 1) // "p2" is at index 1 now
    }

    func testPruneEmptyPagesWhenAllEmptyRetainsSinglePage() {
        let p0 = LaunchpadCustomPage(id: "p0", itemIDs: [])
        let p1 = LaunchpadCustomPage(id: "p1", itemIDs: [])

        let (pruned, activeIndex) = LaunchpadCustomPageReconciler.pruneEmptyPages(
            pages: [p0, p1],
            activePageID: "p1"
        )
        XCTAssertEqual(pruned.count, 1)
        XCTAssertTrue(pruned[0].itemIDs.isEmpty)
        XCTAssertEqual(activeIndex, 0)
    }
}
