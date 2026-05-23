import Foundation
import Observation

/// In-memory database for one open document. The store is the source of truth
/// while the document is open; serialization (FileWrapper layout) is handled
/// by `ScanDocument`/`ScanPackage`. Bulk content (icons, strings dumps) lives
/// on disk via `BlobStore` — only metadata sits in memory.
///
/// ## Performance design
///
/// Three indexes are maintained incrementally on every `upsert` so detail and
/// sidebar views never have to scan the full item collection:
///
/// - `categoryCounts: [ItemCategory: Int]` — drives sidebar count badges.
///   Without this, the sidebar would re-iterate all items on every render.
/// - `pathReferencedBy: [String: [UUID]]` — inverse adjacency. For each
///   `targetPath` mentioned in any item's `relationships`, the list of items
///   pointing at it. Powers DetailView's "Referenced By" section in O(1)
///   instead of O(N × E) per render.
/// - `itemsByOwningBundle: [String: [UUID]]` — bundle contents. Lets the
///   detail view show what lives inside a `.app` / `.framework` / `.kext`
///   without filtering the whole store.
///
/// All three are reset along with `items` and `itemsByPath` in `reset()`. They
/// are NOT persisted to disk — they're rebuilt on document load via `load()`.
@Observable
final class ScanStore {
    var systemInfo: SystemInfo?
    var options: ScanOptions = ScanOptions()
    var lastScanStarted: Date?
    var lastScanCompleted: Date?

    private(set) var items: [UUID: ScanItem] = [:]
    private(set) var itemsByPath: [String: UUID] = [:]

    // Derived indexes — invariants enforced by upsert/remove.
    private(set) var categoryCounts: [ItemCategory: Int] = [:]
    private(set) var pathReferencedBy: [String: [UUID]] = [:]
    private(set) var itemsByOwningBundle: [String: [UUID]] = [:]

    let blobStore: BlobStore = BlobStore()

    // MARK: - Mutation

    func reset() {
        items.removeAll()
        itemsByPath.removeAll()
        categoryCounts.removeAll()
        pathReferencedBy.removeAll()
        itemsByOwningBundle.removeAll()
        systemInfo = nil
        lastScanStarted = nil
        lastScanCompleted = nil
    }

    func upsert(_ item: ScanItem) {
        if let existingID = itemsByPath[item.path], let existing = items[existingID] {
            // Update path: tear down derived edges of the old item, then add
            // back for the new one. The UUID stays — keeps UI selection stable.
            removeIndexes(for: existing)
            let updated = item.withId(existingID)
            items[existingID] = updated
            addIndexes(for: updated)
        } else {
            items[item.id] = item
            itemsByPath[item.path] = item.id
            addIndexes(for: item)
        }
    }

    /// Bulk insert from a scan. The throttled scanner calls this once per
    /// batch (≈ every 250 ms), so we get one SwiftUI re-render per flush.
    func ingest(_ produced: [ScanItem]) {
        for item in produced { upsert(item) }
    }

    private func addIndexes(for item: ScanItem) {
        categoryCounts[item.category, default: 0] += 1
        for rel in item.relationships {
            pathReferencedBy[rel.targetPath, default: []].append(item.id)
        }
        if let owning = item.owningBundlePath {
            itemsByOwningBundle[owning, default: []].append(item.id)
        }
    }

    private func removeIndexes(for item: ScanItem) {
        categoryCounts[item.category, default: 0] -= 1
        for rel in item.relationships {
            pathReferencedBy[rel.targetPath]?.removeAll { $0 == item.id }
            if pathReferencedBy[rel.targetPath]?.isEmpty == true {
                pathReferencedBy.removeValue(forKey: rel.targetPath)
            }
        }
        if let owning = item.owningBundlePath {
            itemsByOwningBundle[owning]?.removeAll { $0 == item.id }
            if itemsByOwningBundle[owning]?.isEmpty == true {
                itemsByOwningBundle.removeValue(forKey: owning)
            }
        }
    }

    // MARK: - Blob access

    func blob(forRef ref: String) -> Data? {
        blobStore.data(forRef: ref)
    }

    // MARK: - Queries

    func items(in category: ItemCategory) -> [ScanItem] {
        items.values.filter { $0.category == category }
    }

    func item(atPath path: String) -> ScanItem? {
        guard let id = itemsByPath[path] else { return nil }
        return items[id]
    }

    /// Items that reference this path via outgoing relationships.
    /// O(1) lookup + O(K) materialization where K is the incoming degree.
    func incomingReferences(toPath path: String) -> [ScanItem] {
        guard let ids = pathReferencedBy[path] else { return [] }
        return ids.compactMap { items[$0] }
    }

    /// Items whose `owningBundlePath` is this path. O(1) + O(K).
    func contents(ofBundleAtPath bundlePath: String) -> [ScanItem] {
        guard let ids = itemsByOwningBundle[bundlePath] else { return [] }
        return ids.compactMap { items[$0] }
    }

    /// Legacy plain-text search retained for the simple-search code path.
    /// The richer `SearchQuery`-based filter lives in `Search/SearchQuery.swift`.
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

    /// Index-backed counts — drives sidebar without recomputation.
    func counts() -> [ItemCategory: Int] {
        var counts: [ItemCategory: Int] = [:]
        for category in ItemCategory.allCases {
            counts[category] = categoryCounts[category] ?? 0
        }
        return counts
    }

    // MARK: - Load

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
            addIndexes(for: item)
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
