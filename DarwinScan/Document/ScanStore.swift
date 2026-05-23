import Foundation
import Observation

/// In-memory database for one open document. The store is the source of truth
/// while the document is open; serialization (FileWrapper layout) is handled
/// by `ScanDocument`/`ScanPackage`.
///
/// We keep two indexes: `items` keyed by UUID (for stable identity across UI
/// renders), and `itemsByPath` for O(1) duplicate detection during scanning.
/// Bulk content (icons, strings dumps) lives on disk via `BlobStore` — only
/// metadata sits in memory.
@Observable
final class ScanStore {
    var systemInfo: SystemInfo?
    var options: ScanOptions = ScanOptions()
    /// Wall-clock when the most recent scan started / completed.
    var lastScanStarted: Date?
    var lastScanCompleted: Date?

    private(set) var items: [UUID: ScanItem] = [:]
    private(set) var itemsByPath: [String: UUID] = [:]

    /// Disk-backed payload store. Empty until a scan or a load registers refs.
    let blobStore: BlobStore = BlobStore()

    // MARK: - Mutation (all on MainActor by default isolation)

    func reset() {
        items.removeAll()
        itemsByPath.removeAll()
        // Note: we leave blobStore intact across resets. Refs are content-
        // addressed so old ones become orphaned but they're idempotent on
        // re-scan. A future "compact" command can prune unreferenced blobs.
        systemInfo = nil
        lastScanStarted = nil
        lastScanCompleted = nil
    }

    func upsert(_ item: ScanItem) {
        if let existing = itemsByPath[item.path] {
            items[existing] = item.withId(existing)
        } else {
            items[item.id] = item
            itemsByPath[item.path] = item.id
        }
    }

    /// Bulk insert from a scan. Preserves identity when paths match an existing
    /// entry so the UI selection stays stable across rescans. Designed to be
    /// called once per throttled batch — drives a single SwiftUI re-render
    /// rather than N.
    func ingest(_ produced: [ScanItem]) {
        for item in produced {
            upsert(item)
        }
    }

    // MARK: - Blob access (forwarded to the underlying BlobStore)

    func blob(forRef ref: String) -> Data? {
        blobStore.data(forRef: ref)
    }

    // MARK: - Queries

    func items(in category: ItemCategory) -> [ScanItem] {
        items.values.filter { $0.category == category }
    }

    /// Resolve a relationship's target path back into an item, if it exists
    /// in this scan. Used by the detail view to make "Related" rows clickable.
    func item(atPath path: String) -> ScanItem? {
        guard let id = itemsByPath[path] else { return nil }
        return items[id]
    }

    func search(_ query: String, scope: ItemCategory? = nil) -> [ScanItem] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            if let s = scope { return items(in: s) }
            return Array(items.values)
        }
        return items.values.filter { item in
            if let s = scope, item.category != s { return false }
            if item.name.lowercased().contains(q) { return true }
            if item.path.lowercased().contains(q) { return true }
            if let context = item.context?.lowercased(), context.contains(q) { return true }
            if item.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
            if let usage = item.executable?.usageLine?.lowercased(), usage.contains(q) { return true }
            if let label = item.launchService?.label?.lowercased(), label.contains(q) { return true }
            if let bundleId = item.application?.bundleIdentifier?.lowercased(), bundleId.contains(q) { return true }
            return false
        }
    }

    /// Aggregate counts. Cheap to recompute — items max out in the low tens
    /// of thousands for a /System scan.
    func counts() -> [ItemCategory: Int] {
        var counts: [ItemCategory: Int] = [:]
        for category in ItemCategory.allCases { counts[category] = 0 }
        for item in items.values { counts[item.category, default: 0] += 1 }
        return counts
    }

    /// Loads a previously-serialized payload. Used by ScanDocument.read.
    func load(
        items: [ScanItem],
        systemInfo: SystemInfo?,
        options: ScanOptions?,
        lastScanStarted: Date?,
        lastScanCompleted: Date?
    ) {
        reset()
        for item in items {
            self.items[item.id] = item
            self.itemsByPath[item.path] = item.id
        }
        self.systemInfo = systemInfo
        if let options { self.options = options }
        self.lastScanStarted = lastScanStarted
        self.lastScanCompleted = lastScanCompleted
    }
}

private extension ScanItem {
    func withId(_ newId: UUID) -> ScanItem {
        var copy = self
        copy.id = newId
        return copy
    }
}
