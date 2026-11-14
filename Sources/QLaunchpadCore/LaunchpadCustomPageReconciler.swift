import Foundation

public enum LaunchpadCustomPageReconciler {
    /// Reconciles an array of custom pages against a current list of root items.
    ///
    /// - Parameters:
    ///   - pages: The existing custom pages (may be empty or contain obsolete IDs).
    ///   - rootItemIDs: The complete valid set of root item IDs in order.
    ///   - capacity: Maximum number of items per page.
    /// - Returns: A validated list of custom pages, where every item in `rootItemIDs`
    ///   is present exactly once, no obsolete items exist, and each page has at most `capacity` items.
    public static func reconcile(
        pages: [LaunchpadCustomPage],
        rootItemIDs: [String],
        capacity: Int
    ) -> [LaunchpadCustomPage] {
        let maxCap = max(1, capacity)
        let validIDs = Set(rootItemIDs)

        // 1. If existing pages is empty, chunk rootItemIDs by capacity
        guard !pages.isEmpty else {
            return chunkItems(rootItemIDs, capacity: maxCap)
        }

        // 2. Remove obsolete or duplicate IDs from existing pages
        var seen = Set<String>()
        var reconciledPages: [LaunchpadCustomPage] = []
        for page in pages {
            var items: [String] = []
            for id in page.itemIDs {
                if validIDs.contains(id) && seen.insert(id).inserted {
                    items.append(id)
                }
            }
            reconciledPages.append(LaunchpadCustomPage(id: page.id, itemIDs: items))
        }

        // 3. Find any root items not present in pages and append them to the last page (expand if needed)
        let missingIDs = rootItemIDs.filter { !seen.contains($0) }
        for id in missingIDs {
            if reconciledPages.isEmpty {
                reconciledPages.append(LaunchpadCustomPage(id: UUID().uuidString, itemIDs: [id]))
            } else {
                let lastIndex = reconciledPages.count - 1
                if reconciledPages[lastIndex].itemIDs.count < maxCap {
                    reconciledPages[lastIndex].itemIDs.append(id)
                } else {
                    reconciledPages.append(LaunchpadCustomPage(id: UUID().uuidString, itemIDs: [id]))
                }
            }
        }

        // 4. Split any pages that exceed capacity (e.g. if grid density decreased)
        var result: [LaunchpadCustomPage] = []
        for page in reconciledPages {
            if page.itemIDs.count <= maxCap {
                result.append(page)
            } else {
                let chunks = stride(from: 0, to: page.itemIDs.count, by: maxCap).map {
                    Array(page.itemIDs[$0..<min($0 + maxCap, page.itemIDs.count)])
                }
                for (chunkIndex, chunk) in chunks.enumerated() {
                    let pageID = chunkIndex == 0 ? page.id : UUID().uuidString
                    result.append(LaunchpadCustomPage(id: pageID, itemIDs: chunk))
                }
            }
        }

        // Always retain at least one page
        if result.isEmpty {
            result.append(LaunchpadCustomPage())
        }
        return result
    }

    /// Split a list of item IDs into pages of at most `capacity` items.
    public static func chunkItems(_ items: [String], capacity: Int) -> [LaunchpadCustomPage] {
        let maxCap = max(1, capacity)
        guard !items.isEmpty else {
            return [LaunchpadCustomPage()]
        }
        var pages: [LaunchpadCustomPage] = []
        for chunk in stride(from: 0, to: items.count, by: maxCap) {
            let slice = Array(items[chunk..<min(chunk + maxCap, items.count)])
            pages.append(LaunchpadCustomPage(id: UUID().uuidString, itemIDs: slice))
        }
        return pages
    }

    /// Cascades overflow from a given page index downward.
    /// If a page has more than `capacity` items, the extra items are pushed to the next page.
    public static func cascadeOverflow(
        pages: inout [LaunchpadCustomPage],
        startingAt pageIndex: Int,
        capacity: Int
    ) {
        let maxCap = max(1, capacity)
        var index = pageIndex
        while index < pages.count {
            if pages[index].itemIDs.count <= maxCap {
                break
            }
            let overflowCount = pages[index].itemIDs.count - maxCap
            let overflow = Array(pages[index].itemIDs.suffix(overflowCount))
            pages[index].itemIDs.removeLast(overflowCount)

            if index + 1 < pages.count {
                pages[index + 1].itemIDs.insert(contentsOf: overflow, at: 0)
                index += 1
            } else {
                pages.append(LaunchpadCustomPage(id: UUID().uuidString, itemIDs: overflow))
                index += 1
            }
        }
    }

    /// Prunes completely empty pages at commit time, keeping at least one page.
    /// Tracks and updates the active page index so the user doesn't jump to an unexpected location.
    public static func pruneEmptyPages(
        pages: [LaunchpadCustomPage],
        activePageID: String?,
        fallbackIndex: Int = 0
    ) -> (pages: [LaunchpadCustomPage], activeIndex: Int) {
        var nonEmpties = pages.filter { !$0.itemIDs.isEmpty }
        if nonEmpties.isEmpty {
            nonEmpties = [LaunchpadCustomPage()]
        }

        let newIndex: Int
        if let activePageID, let idx = nonEmpties.firstIndex(where: { $0.id == activePageID }) {
            newIndex = idx
        } else {
            newIndex = min(max(fallbackIndex, 0), nonEmpties.count - 1)
        }
        return (nonEmpties, newIndex)
    }
}
