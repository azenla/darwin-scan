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

    /// Snapshot ID of the previous scan (the parent of `currentSnapshotID`),
    /// if any. Used by `diffAgainstParent()` to decide whether the
    /// in-progress scan actually changed anything.
    public private(set) var parentSnapshotID: Int64?

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

    /// Clear the in-memory state so a new scan starts from a clean slate.
    /// Does NOT clear the SQLite database — items from previous snapshots
    /// stay around so the diff against parent can run, and so deterministic
    /// upserts (same id → same row) reuse existing storage.
    ///
    /// For the "user wants to truly wipe this document" gesture, delete the
    /// `.darwinscan` bundle on disk and start over.
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
        parentSnapshotID = nil
        cachedHistory = nil
    }

    /// Repopulate the in-memory view from the latest snapshot's items.
    /// Used by `ScanController` after `discardCurrentSnapshot()` so the
    /// view returns to the parent snapshot's state instead of remaining
    /// half-populated by the just-cancelled scan.
    public func reloadFromLatestSnapshot() {
        guard let database else {
            reset()
            return
        }
        let latest = (try? database.latestSnapshotID()) ?? nil
        let loadedItems: [ScanItem]
        if let id = latest {
            loadedItems = (try? database.itemsForSnapshot(id)) ?? []
        } else {
            loadedItems = []
        }
        // Take the snapshot's recorded system_info too, so toolbar /
        // SystemInfoView reflect the snapshot we're viewing.
        let snapshot = (try? database.allSnapshots())?.first
        let attached = self.database
        self.database = nil
        items.removeAll()
        itemsByPath.removeAll()
        categoryCounts.removeAll()
        pathReferencedBy.removeAll()
        itemsByOwningBundle.removeAll()
        for item in loadedItems {
            let header = ItemHeader(from: item)
            self.items[item.id] = header
            self.itemsByPath[item.path] = item.id
            addIndexes(forID: item.id, header: header, relationships: item.relationships)
        }
        self.systemInfo = snapshot?.systemInfo
        self.lastScanStarted = snapshot?.startedAt
        self.lastScanCompleted = snapshot?.completedAt
        self.database = attached
    }

    // MARK: - Snapshot lifecycle

    /// Open a new snapshot row in the database and stamp `currentSnapshotID`.
    /// The next `ingest` will record per-item membership in this snapshot.
    ///
    /// Chains off the previous snapshot via `parent_id` so the history is a
    /// single linked list. Captures `SystemInfo` (sw_vers, hardware, SIP
    /// state) into the snapshot row so a future diff command can show OS-
    /// level changes even when no scan items moved.
    public func beginSnapshot(at startedAt: Date = Date(), label: String? = nil, systemInfo: SystemInfo? = nil) {
        guard let database else { return }
        do {
            let parent = try database.latestSnapshotID()
            let infoBytes: Data? = systemInfo.flatMap {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try? encoder.encode($0)
            }
            let id = try database.insertSnapshot(
                parentID: parent,
                label: label,
                startedAt: startedAt,
                completedAt: nil,
                systemInfo: infoBytes
            )
            currentSnapshotID = id
            parentSnapshotID = parent
            cachedHistory = nil
        } catch {
            print("[ScanStore] beginSnapshot failed: \(error)")
        }
    }

    /// Discard the in-progress snapshot — delete its `snapshots` row and
    /// `snapshot_items` membership. Used by the "no changes since previous
    /// snapshot" finalization path. Items themselves stay in `items` (other
    /// snapshots may reference them); only the membership and the snapshot
    /// row are removed.
    public func discardCurrentSnapshot() {
        guard let database, let id = currentSnapshotID else { return }
        do {
            try database.deleteSnapshot(id: id)
        } catch {
            print("[ScanStore] discardCurrentSnapshot failed: \(error)")
        }
        currentSnapshotID = nil
        cachedHistory = nil
    }

    /// Snapshot diff: returns the (added, removed, changed) sets between
    /// the current snapshot and its parent. "Changed" means same path, but
    /// different content (deterministic id differs). Called by the scan
    /// finalize path to decide whether to keep the new snapshot.
    public func diffAgainstParent() -> (added: Set<UUID>, removed: Set<UUID>, changed: Set<String>)? {
        guard let database,
              let currentID = currentSnapshotID else { return nil }
        let current = (try? database.itemsInSnapshot(currentID)) ?? []
        guard let parentID = parentSnapshotID else {
            // First snapshot in the bundle — everything is "added".
            return (added: current, removed: [], changed: [])
        }
        let parent = (try? database.itemsInSnapshot(parentID)) ?? []
        let added = current.subtracting(parent)
        let removed = parent.subtracting(current)
        // Walk added+removed and look for path collisions — those are
        // content changes at the same path.
        var addedByPath: [String: UUID] = [:]
        for id in added {
            if let h = items[id] { addedByPath[h.path] = id }
        }
        var removedByPath: [String: UUID] = [:]
        for id in removed {
            // Removed IDs are no longer in the in-memory store. Look them
            // up by joining `items` directly.
            if let item = try? database.item(id: id) {
                removedByPath[item.path] = id
            }
        }
        var changed: Set<String> = []
        for (path, _) in addedByPath where removedByPath[path] != nil {
            changed.insert(path)
        }
        return (added, removed, changed)
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

    /// Finalize the in-progress snapshot: compute the diff against the
    /// parent snapshot, discard the new row if nothing changed, otherwise
    /// stamp completed_at and keep it. Returns a summary so the caller can
    /// surface "wrote N items, X added / Y changed / Z removed" or
    /// "discarded — nothing changed since previous scan."
    ///
    /// "Nothing changed" means the deterministic id sets for the current
    /// and parent snapshots are identical. Per the identity rules: same
    /// (path, sha256) → same id; any byte-level change yields a new id at
    /// the same path. So set equality is a true content equality check
    /// for hashed files. Unhashed files use random UUIDs and therefore
    /// always look "different" — disable hashing only when you don't care
    /// about cross-scan diff.
    @discardableResult
    public func finalizeScan(at completedAt: Date = Date()) -> FinalizeResult {
        guard let database, let currentID = currentSnapshotID else {
            return FinalizeResult(kind: .noSnapshot, added: 0, removed: 0, changed: 0)
        }
        let diff = diffAgainstParent() ?? (added: [], removed: [], changed: [])
        let unchanged = diff.added.isEmpty && diff.removed.isEmpty && diff.changed.isEmpty
        if unchanged && parentSnapshotID != nil {
            // Identical to parent — discard the new snapshot row + items
            // membership. The parent snapshot remains the latest.
            discardCurrentSnapshot()
            return FinalizeResult(kind: .discarded, added: 0, removed: 0, changed: 0)
        }
        do {
            try database.completeSnapshot(id: currentID, at: completedAt)
        } catch {
            print("[ScanStore] completeSnapshot failed: \(error)")
        }
        lastScanCompleted = completedAt
        cachedHistory = nil
        return FinalizeResult(
            kind: .kept,
            added: diff.added.count,
            removed: diff.removed.count,
            changed: diff.changed.count
        )
    }

    public struct FinalizeResult: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case noSnapshot  // beginSnapshot was never called
            case kept        // snapshot retained because something changed
            case discarded   // identical to parent — row removed
        }
        public let kind: Kind
        public let added: Int
        public let removed: Int
        public let changed: Int
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
        // The production scan pipelines call `beginSnapshot()` explicitly
        // before `ingest()` so the new snapshot's `system_info` is captured
        // and the parent chain is set. Direct-API callers (tests, future
        // tooling) might forget, so we lazily start a snapshot here — the
        // alternative is silently dropping items on the floor when no
        // snapshot is open.
        if currentSnapshotID == nil, database != nil {
            // Carry the pre-set `systemInfo` (if any) into the snapshot row
            // so direct-API callers who do `store.systemInfo = ...` followed
            // by `store.ingest(...)` get their sw_vers preserved across
            // save/load. Production paths set systemInfo via their own
            // beginSnapshot(systemInfo:) call before ingest is reached.
            beginSnapshot(systemInfo: self.systemInfo)
        }
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
