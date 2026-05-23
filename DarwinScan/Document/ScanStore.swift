import Foundation
import Observation

/// In-memory database for one open document. The store is the source of truth
/// while the document is open; serialization (FileWrapper layout) is handled
/// by `ScanDocument`/`ScanPackage`.
///
/// We keep two indexes: `items` keyed by UUID (for stable identity across UI
/// renders), and `itemsByPath` for O(1) duplicate detection during scanning.
/// Both are pure-Swift dictionaries — performance is dominated by I/O.
@Observable
final class ScanStore {
    var systemInfo: SystemInfo?
    var options: ScanOptions = ScanOptions()
    /// Wall-clock when the most recent scan started / completed.
    var lastScanStarted: Date?
    var lastScanCompleted: Date?

    private(set) var items: [UUID: ScanItem] = [:]
    private(set) var itemsByPath: [String: UUID] = [:]

    /// Content-addressed payload registry. Key: blob ref (sha256-prefixed).
    /// Value: arbitrary bytes — strings extracts, icon PNGs, etc.
    private(set) var blobs: [String: Data] = [:]

    // MARK: - Mutation (all on MainActor by default isolation)

    func reset() {
        items.removeAll()
        itemsByPath.removeAll()
        blobs.removeAll()
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

    /// Bulk insert from a scan; preserves identity when paths match an existing
    /// entry so the UI selection stays stable across rescans.
    func ingest(_ produced: [ScanItem]) {
        for item in produced {
            upsert(item)
        }
    }

    /// Store a payload addressed by SHA-256 of its bytes. Returns the ref to
    /// embed in an item's payload. Idempotent — duplicate content reuses the
    /// same ref, so an icon shared by 50 .apps occupies one blob.
    @discardableResult
    func storeBlob(_ data: Data, hint: String = "") -> String {
        let digest = Hash.sha256Hex(data)
        let ref = hint.isEmpty ? digest : "\(hint)-\(digest)"
        blobs[ref] = data
        return ref
    }

    /// Direct insertion when the caller has already computed the ref — used by
    /// the scanner ingest path where the worker computes the digest off-thread.
    func setBlob(_ data: Data, forRef ref: String) {
        blobs[ref] = data
    }

    func blob(forRef ref: String) -> Data? { blobs[ref] }

    // MARK: - Queries

    func items(in category: ItemCategory) -> [ScanItem] {
        items.values.filter { $0.category == category }
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
        blobs: [String: Data],
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
        self.blobs = blobs
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
