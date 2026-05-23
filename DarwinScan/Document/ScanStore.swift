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
    var systemInfo: SystemInfo? {
        didSet { persistMeta("system_info", value: systemInfo) }
    }
    var options: ScanOptions = ScanOptions() {
        didSet { persistMeta("options", value: options) }
    }
    var lastScanStarted: Date? {
        didSet { persistMeta("last_scan_started", value: lastScanStarted) }
    }
    var lastScanCompleted: Date? {
        didSet { persistMeta("last_scan_completed", value: lastScanCompleted) }
    }

    private(set) var items: [UUID: ScanItem] = [:]
    private(set) var itemsByPath: [String: UUID] = [:]

    // Derived indexes — invariants enforced by upsert/remove.
    private(set) var categoryCounts: [ItemCategory: Int] = [:]
    private(set) var pathReferencedBy: [String: [UUID]] = [:]
    private(set) var itemsByOwningBundle: [String: [UUID]] = [:]

    let blobStore: BlobStore = BlobStore()

    /// Optional persistent backing. When attached, every mutation is mirrored
    /// to SQLite so the on-disk `data.db` stays current. The in-memory store
    /// remains the source of truth — the database is for crash safety and a
    /// foundation for future lazy-loading paths.
    private(set) var database: Database?

    /// Where the attached `data.db` lives on disk. `ScanPackage.makeFileWrapper`
    /// needs this to stream the file into the saved bundle. Set alongside
    /// `attachDatabase`.
    var databaseURL: URL?

    /// Attach (or detach) the persistent database. Called by `ScanDocument`
    /// once it has decided where on disk to keep `data.db`. Subsequent
    /// `upsert`/`ingest`/`reset` calls write through.
    func attachDatabase(_ db: Database?) {
        self.database = db
    }

    /// Encode a single meta value to the attached database. Failures are
    /// logged but non-fatal — losing one metadata write shouldn't abort a
    /// scan in progress. Skipped when no database is attached or the value
    /// is nil (we currently persist the *last set* value; a future migration
    /// can add explicit deletes if we need them).
    private func persistMeta<T: Encodable>(_ key: String, value: T?) {
        guard let database, let value else { return }
        do {
            try database.setMeta(key, value: value)
        } catch {
            print("[ScanStore] persistMeta(\(key)) failed: \(error)")
        }
    }

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
        // Mirror the wipe to the persistent layer so reopening the doc
        // doesn't resurrect stale rows.
        if let database {
            do { try database.clearItems() } catch {
                print("[ScanStore] database.clearItems failed: \(error)")
            }
        }
    }

    func upsert(_ item: ScanItem) {
        let written: ScanItem
        if let existingID = itemsByPath[item.path], let existing = items[existingID] {
            // Update path: tear down derived edges of the old item, then add
            // back for the new one. The UUID stays — keeps UI selection stable.
            removeIndexes(for: existing)
            let updated = item.withId(existingID)
            items[existingID] = updated
            addIndexes(for: updated)
            written = updated
        } else {
            items[item.id] = item
            itemsByPath[item.path] = item.id
            addIndexes(for: item)
            written = item
        }
        if let database {
            do { try database.upsertItem(written) } catch {
                print("[ScanStore] database.upsertItem failed: \(error)")
            }
        }
    }

    /// Bulk insert from a scan. The throttled scanner calls this once per
    /// batch (≈ every 250 ms), so we get one SwiftUI re-render per flush.
    ///
    /// Persists the batch in a single SQLite transaction. We collect the
    /// post-merge items separately so the database always sees the same UUIDs
    /// the in-memory store uses (path collisions reuse the existing id).
    func ingest(_ produced: [ScanItem]) {
        // Apply to memory first, capturing the actually-stored rows so the
        // database mirrors the same UUIDs.
        var persisted: [ScanItem] = []
        persisted.reserveCapacity(produced.count)
        for item in produced {
            let stored: ScanItem
            if let existingID = itemsByPath[item.path], let existing = items[existingID] {
                removeIndexes(for: existing)
                let updated = item.withId(existingID)
                items[existingID] = updated
                addIndexes(for: updated)
                stored = updated
            } else {
                items[item.id] = item
                itemsByPath[item.path] = item.id
                addIndexes(for: item)
                stored = item
            }
            persisted.append(stored)
        }
        if let database {
            do { try database.upsertItems(persisted) } catch {
                print("[ScanStore] database.upsertItems failed: \(error)")
            }
        }
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

    /// Replace the store's contents wholesale. Used when opening a document
    /// (where rows come from `Database.allItems()` and the database is also
    /// attached, so we suppress mirror-writes here) and historically by the
    /// legacy JSON loader. Pass `mirrorToDatabase: true` to also seed an
    /// attached database — useful when migrating a legacy JSON bundle on open.
    func load(
        items: [ScanItem],
        systemInfo: SystemInfo?,
        options: ScanOptions?,
        lastScanStarted: Date?,
        lastScanCompleted: Date?,
        mirrorToDatabase: Bool = false
    ) {
        // Temporarily detach the database during the rebuild so we don't write
        // every item back to a database we just read it from.
        let attached = self.database
        self.database = nil
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
        self.database = attached

        if mirrorToDatabase, let attached {
            do {
                try attached.upsertItems(items)
                if let systemInfo {
                    try attached.setMeta("system_info", value: systemInfo)
                }
                if let options {
                    try attached.setMeta("options", value: options)
                }
                if let lastScanStarted {
                    try attached.setMeta("last_scan_started", value: lastScanStarted)
                }
                if let lastScanCompleted {
                    try attached.setMeta("last_scan_completed", value: lastScanCompleted)
                }
            } catch {
                print("[ScanStore] mirrorToDatabase failed: \(error)")
            }
        }
    }
}

private extension ScanItem {
    func withId(_ newId: UUID) -> ScanItem {
        var copy = self
        copy.id = newId
        return copy
    }
}
