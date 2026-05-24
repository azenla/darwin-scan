import Foundation
import Observation

/// In-memory store for one open document. SQLite (`data.db`) is the persistent
/// source of truth for full `ScanItem` payloads; this class keeps a slim
/// `ItemHeader` for every item in memory plus a handful of derived indexes so
/// search, lists, and sidebar counts don't pay per-row disk reads.
///
/// ## Tiering
///
/// - **Always in RAM** — one `ItemHeader` per item (~200-300 B). The header
///   carries every field the list, sidebar, and search engine consult, so a
///   global filter over hundreds of thousands of items never has to round-trip
///   through SQLite.
/// - **On demand** — full `ScanItem` (with relationships, full executable
///   info, etc.). Fetched via `fullItem(id:)` when the detail view opens.
///   A typical session touches a few dozen items here, not the whole store.
///
/// This is the "SQLite primary, in-memory working set" architecture flagged in
/// CLAUDE.md. For a /System scan it's ~5-10× less RAM than holding full
/// `ScanItem` values for every row.
///
/// ## Indexes
///
/// Three derived indexes are maintained incrementally on every upsert:
///
/// - `categoryCounts: [ItemCategory: Int]` — sidebar count badges in O(1).
/// - `pathReferencedBy: [String: [UUID]]` — inverse adjacency: for each
///   `targetPath` mentioned in any item's relationships, the list of items
///   pointing at it. Powers "Referenced By" in O(1).
/// - `itemsByOwningBundle: [String: [UUID]]` — bundle contents.
///
/// All three are reset along with `items`/`itemsByPath`/`itemHeaders` in
/// `reset()` and rebuilt on document load. They are NOT persisted.
///
/// ## Path-collision upserts
///
/// When a rescan touches a path that already has an item, the in-memory
/// `ItemHeader` doesn't carry the previous outgoing relationships (those are
/// only in SQLite). We query `Database.outgoingTargets(sourceID:)` right before
/// the upsert to know which paths to scrub from `pathReferencedBy`. For
/// initial scans nothing collides, so this query never fires.
@Observable
public nonisolated final class ScanStore {
    public var systemInfo: SystemInfo? {
        didSet { persistMeta("system_info", value: systemInfo) }
    }
    public var options: ScanOptions = ScanOptions() {
        didSet { persistMeta("options", value: options) }
    }
    public var lastScanStarted: Date? {
        didSet { persistMeta("last_scan_started", value: lastScanStarted) }
    }
    public var lastScanCompleted: Date? {
        didSet { persistMeta("last_scan_completed", value: lastScanCompleted) }
    }

    /// In-memory map of all items, slim form. Full payloads come from SQLite
    /// via `fullItem(id:)`.
    public private(set) var items: [UUID: ItemHeader] = [:]
    public private(set) var itemsByPath: [String: UUID] = [:]

    // Derived indexes — invariants enforced by upsert/remove.
    public private(set) var categoryCounts: [ItemCategory: Int] = [:]
    public private(set) var pathReferencedBy: [String: [UUID]] = [:]
    public private(set) var itemsByOwningBundle: [String: [UUID]] = [:]

    public let blobStore: BlobStore = BlobStore()

    /// Optional persistent backing. When attached, every mutation is mirrored
    /// to SQLite so the on-disk `data.db` stays current.
    public private(set) var database: Database?

    /// Where the attached `data.db` lives on disk. `ScanPackage.makeFileWrapper`
    /// needs this to stream the file into the saved bundle. Set alongside
    /// `attachDatabase`.
    public var databaseURL: URL?

    /// Active snapshot ID for the in-progress scan. nil when no scan is
    /// running. `ingest` mirrors items into `snapshot_items(snapshotID, item)`
    /// when this is set so the new snapshot's membership is recorded.
    public private(set) var currentSnapshotID: Int64?

    /// Read-only snapshot history, newest-first. Loaded lazily by the
    /// `snapshotHistory()` call and cached until `beginSnapshot` invalidates.
    private var cachedHistory: [SnapshotRecord]?

    public init() {}

    /// Attach (or detach) the persistent database. Called by `ScanDocument`
    /// once it has decided where on disk to keep `data.db`. Subsequent
    /// `upsert`/`ingest`/`reset` calls write through.
    public func attachDatabase(_ db: Database?) {
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

    public func reset() {
        items.removeAll()
        itemsByPath.removeAll()
        categoryCounts.removeAll()
        pathReferencedBy.removeAll()
        itemsByOwningBundle.removeAll()
        systemInfo = nil
        lastScanStarted = nil
        lastScanCompleted = nil
        currentSnapshotID = nil
        cachedHistory = nil
        // Mirror the wipe to the persistent layer so reopening the doc
        // doesn't resurrect stale rows.
        if let database {
            do { try database.clearItems() } catch {
                print("[ScanStore] database.clearItems failed: \(error)")
            }
        }
    }

    // MARK: - Snapshot lifecycle

    /// Open a new snapshot row in the database and stamp `currentSnapshotID`.
    /// The next `ingest` will record per-item membership in this snapshot.
    ///
    /// Chains off the previous snapshot via `parent_id` so the history is a
    /// single linked list — that's what a future diff command will walk.
    public func beginSnapshot(at startedAt: Date = Date(), label: String? = nil) {
        guard let database else { return }
        do {
            let parent = try database.latestSnapshotID()
            let id = try database.insertSnapshot(
                parentID: parent,
                label: label,
                startedAt: startedAt,
                completedAt: nil
            )
            currentSnapshotID = id
            cachedHistory = nil
        } catch {
            print("[ScanStore] beginSnapshot failed: \(error)")
        }
    }

    /// Mark the current snapshot as finished. No-op if no snapshot is open.
    public func completeCurrentSnapshot(at completedAt: Date = Date()) {
        guard let database, let id = currentSnapshotID else { return }
        do {
            try database.completeSnapshot(id: id, at: completedAt)
        } catch {
            print("[ScanStore] completeSnapshot failed: \(error)")
        }
        cachedHistory = nil
        // Leave currentSnapshotID set — a saved bundle should still report
        // "this is the latest snapshot". reset() is what clears it.
    }

    public func snapshotHistory() -> [SnapshotRecord] {
        if let cachedHistory { return cachedHistory }
        guard let database else { return [] }
        let history = (try? database.allSnapshots()) ?? []
        cachedHistory = history
        return history
    }

    public func upsert(_ item: ScanItem) {
        let written: ScanItem
        if let existingID = itemsByPath[item.path], let existing = items[existingID] {
            // Update path: tear down derived edges of the old item, then add
            // back for the new one. The UUID stays — keeps UI selection stable.
            // Outgoing targets aren't in the in-memory header, so query SQLite
            // for the previous edges before we overwrite them.
            let oldTargets = (try? database?.outgoingTargets(sourceID: existingID)) ?? []
            removeIndexes(forID: existingID, header: existing, outgoingTargets: oldTargets)
            let updated = item.withId(existingID)
            let header = ItemHeader(from: updated)
            items[existingID] = header
            addIndexes(forID: existingID, header: header, relationships: updated.relationships)
            written = updated
        } else {
            let header = ItemHeader(from: item)
            items[item.id] = header
            itemsByPath[item.path] = item.id
            addIndexes(forID: item.id, header: header, relationships: item.relationships)
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
    ///
    /// Path-collision callers must also call `clearSymbolsForReingest(_:)`
    /// for any UUID being overwritten — symbol rows are keyed by item_id,
    /// and stale rows from the prior scan would otherwise accumulate.
    public func ingest(_ produced: [ScanItem]) {
        // Apply to memory first, capturing the actually-stored rows so the
        // database mirrors the same UUIDs.
        var persisted: [ScanItem] = []
        persisted.reserveCapacity(produced.count)
        for item in produced {
            let stored: ScanItem
            if let existingID = itemsByPath[item.path], let existing = items[existingID] {
                let oldTargets = (try? database?.outgoingTargets(sourceID: existingID)) ?? []
                removeIndexes(forID: existingID, header: existing, outgoingTargets: oldTargets)
                let updated = item.withId(existingID)
                let header = ItemHeader(from: updated)
                items[existingID] = header
                addIndexes(forID: existingID, header: header, relationships: updated.relationships)
                stored = updated
            } else {
                let header = ItemHeader(from: item)
                items[item.id] = header
                itemsByPath[item.path] = item.id
                addIndexes(forID: item.id, header: header, relationships: item.relationships)
                stored = item
            }
            persisted.append(stored)
        }
        if let database {
            do { try database.upsertItems(persisted) } catch {
                print("[ScanStore] database.upsertItems failed: \(error)")
            }
            // Record membership in the active snapshot so the bundle
            // history captures exactly which items belonged to this scan.
            if let snapshotID = currentSnapshotID {
                let ids = persisted.map(\.id)
                do { try database.addItemsToSnapshot(snapshotID: snapshotID, itemIDs: ids) } catch {
                    print("[ScanStore] addItemsToSnapshot failed: \(error)")
                }
            }
        }
    }

    /// Index update for a newly-added item. Takes the relationships separately
    /// because the in-memory `ItemHeader` deliberately doesn't carry them — the
    /// caller has the full `ScanItem` at upsert time and passes them through.
    private func addIndexes(forID id: UUID, header: ItemHeader, relationships: [Relationship]) {
        categoryCounts[header.category, default: 0] += 1
        for rel in relationships {
            pathReferencedBy[rel.targetPath, default: []].append(id)
        }
        if let owning = header.owningBundlePath {
            itemsByOwningBundle[owning, default: []].append(id)
        }
    }

    /// Index teardown for an item being replaced. `outgoingTargets` comes
    /// from SQLite via `Database.outgoingTargets(sourceID:)` since the
    /// in-memory header doesn't carry them.
    private func removeIndexes(forID id: UUID, header: ItemHeader, outgoingTargets: [String]) {
        categoryCounts[header.category, default: 0] -= 1
        for target in outgoingTargets {
            pathReferencedBy[target]?.removeAll { $0 == id }
            if pathReferencedBy[target]?.isEmpty == true {
                pathReferencedBy.removeValue(forKey: target)
            }
        }
        if let owning = header.owningBundlePath {
            itemsByOwningBundle[owning]?.removeAll { $0 == id }
            if itemsByOwningBundle[owning]?.isEmpty == true {
                itemsByOwningBundle.removeValue(forKey: owning)
            }
        }
    }

    // MARK: - Blob access

    public func blob(forRef ref: String) -> Data? {
        blobStore.data(forRef: ref)
    }

    // MARK: - Symbol persistence

    /// Bulk-insert symbol rows produced by `SymbolInspector`. The worker
    /// batches these alongside items so the cost is amortised across
    /// hundreds of rows per transaction. Failures are logged and swallowed
    /// — a missing batch of symbols shouldn't abort a scan.
    public func insertSymbols(_ rows: [SymbolRow]) {
        guard !rows.isEmpty, let database else { return }
        do {
            try database.insertSymbols(rows)
        } catch {
            print("[ScanStore] database.insertSymbols failed: \(error)")
        }
    }

    /// On-demand fetch of all symbols for a single item, used by the
    /// detail view. Capped at 5000 by Database; UI shows a "more" affordance
    /// when truncated.
    public func symbols(forItem itemID: UUID) -> [SymbolRow] {
        guard let database else { return [] }
        return (try? database.symbols(forItem: itemID)) ?? []
    }

    public func symbolCount(forItem itemID: UUID) -> Int {
        guard let database else { return 0 }
        return (try? database.symbolCount(forItem: itemID)) ?? 0
    }

    /// Drop symbols for an item that's about to be reingested at the same
    /// path with a fresh sha256. Called by the path-collision branch in the
    /// scan sink before `insertSymbols` for the new content runs.
    public func clearSymbolsForReingest(_ itemID: UUID) {
        guard let database else { return }
        do { try database.deleteSymbols(forItem: itemID) } catch {
            print("[ScanStore] deleteSymbols failed: \(error)")
        }
    }

    /// Global symbol FTS search. Used by the symbol search field once the
    /// UI is wired up.
    public func searchSymbols(_ query: String, limit: Int = 500) -> [SymbolHit] {
        guard let database, !query.isEmpty else { return [] }
        return (try? database.searchSymbols(query: query, limit: limit)) ?? []
    }

    // MARK: - Queries

    public func items(in category: ItemCategory) -> [ItemHeader] {
        items.values.filter { $0.category == category }
    }

    public func item(atPath path: String) -> ItemHeader? {
        guard let id = itemsByPath[path] else { return nil }
        return items[id]
    }

    /// Fetch the full `ScanItem` payload for `id` from SQLite. Synchronous
    /// (Database holds an internal lock; reads are ~ms) — call from
    /// `MainActor` only. Returns `nil` if no database is attached or the
    /// row was deleted between header insert and this call.
    ///
    /// Detail views use this in a `.task(id:)` so the load happens as the
    /// selection changes, not on every body re-render.
    public func fullItem(id: UUID) -> ScanItem? {
        guard let database else { return nil }
        return try? database.item(id: id)
    }

    /// Headers that reference this path via outgoing relationships.
    /// O(1) lookup + O(K) materialization where K is the incoming degree.
    public func incomingReferences(toPath path: String) -> [ItemHeader] {
        guard let ids = pathReferencedBy[path] else { return [] }
        return ids.compactMap { items[$0] }
    }

    /// Same as `incomingReferences(toPath:)` but materializes at most `limit`
    /// items and returns the total count separately. The detail view only
    /// renders the first 64; without this, viewing a popular dylib (libSystem,
    /// CoreFoundation, …) allocated a header for every binary that linked it
    /// just to slice it down to 64 rows.
    public func incomingReferencesPrefix(toPath path: String, limit: Int) -> (total: Int, items: [ItemHeader]) {
        guard let ids = pathReferencedBy[path] else { return (0, []) }
        let prefix = ids.prefix(limit).compactMap { items[$0] }
        return (ids.count, prefix)
    }

    /// Headers whose `owningBundlePath` is this path. O(1) + O(K).
    public func contents(ofBundleAtPath bundlePath: String) -> [ItemHeader] {
        guard let ids = itemsByOwningBundle[bundlePath] else { return [] }
        return ids.compactMap { items[$0] }
    }

    /// Legacy plain-text search retained for the simple-search code path.
    /// The richer `SearchQuery`-based filter lives in `Search/SearchQuery.swift`.
    public func search(_ query: String, scope: ItemCategory? = nil) -> [ItemHeader] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            if let s = scope { return items(in: s) }
            return Array(items.values)
        }
        return items.values.filter { header in
            if let s = scope, header.category != s { return false }
            if header.lowercasedName.contains(q) { return true }
            if header.path.lowercased().contains(q) { return true }
            if let context = header.context?.lowercased(), context.contains(q) { return true }
            if header.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
            if let usage = header.usageLine?.lowercased(), usage.contains(q) { return true }
            if let label = header.launchServiceLabel?.lowercased(), label.contains(q) { return true }
            if let bundleId = header.bundleIdentifier?.lowercased(), bundleId.contains(q) { return true }
            return false
        }
    }

    /// Index-backed counts — drives sidebar without recomputation.
    public func counts() -> [ItemCategory: Int] {
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
    public func load(
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
            // Build the slim header for in-memory storage, but feed indexes
            // from the full ScanItem (we still have it locally) so we don't
            // need a per-item SQLite query for relationships during load.
            let header = ItemHeader(from: item)
            self.items[item.id] = header
            self.itemsByPath[item.path] = item.id
            addIndexes(forID: item.id, header: header, relationships: item.relationships)
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

nonisolated private extension ScanItem {
    func withId(_ newId: UUID) -> ScanItem {
        var copy = self
        copy.id = newId
        return copy
    }
}
