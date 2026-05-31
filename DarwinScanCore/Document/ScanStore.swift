import Foundation
import Observation
import os.lock

/// In-memory façade over the bundle's SQLite database. Holds **no** copy of
/// the items themselves — every per-item access goes through `Database`,
/// with a small LRU cache (`HeaderCache`) so the list view's scroll never
/// pays a hot-loop SQL roundtrip.
///
/// The previous design mirrored every item's `ItemHeader` into a
/// `[UUID: ItemHeader]` dict + maintained two reverse indexes
/// (`pathReferencedBy`, `itemsByOwningBundle`). For a /System-scale
/// snapshot (470k items) that working set alone exceeded **500 MB** of
/// heap, and the app crashed at ~4 GB once the rest of SwiftUI's working
/// state was layered on. The SQL-backed shape uses ~8 MB for the same
/// snapshot.
@Observable
public nonisolated final class ScanStore {
    // MARK: - Document metadata (persisted)

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

    // MARK: - Active-snapshot derived state (small, recomputed on switch)

    /// Snapshot the in-memory view currently reflects. Nil for empty
    /// bundles or while a fresh import is mid-flight.
    public private(set) var activeSnapshotID: Int64?
    /// Per-category counts for the active snapshot. Derived from
    /// `Database.categoryCounts(inSnapshot:)`. Updated on
    /// `setActiveSnapshot(_:)` and when import/analysis finishes.
    public private(set) var categoryCounts: [ItemCategory: Int] = [:]
    /// Total item count for the active snapshot. Cached so the sidebar's
    /// "All Items" badge doesn't pay a SQL roundtrip on every render.
    public private(set) var itemCount: Int = 0

    // MARK: - Backing stores

    public private(set) var blobStore: BlobStore
    public private(set) var database: Database?
    public var databaseURL: URL?

    // MARK: - Import bookkeeping

    public private(set) var importingSnapshotID: Int64?
    public private(set) var importParentSnapshotID: Int64?

    // MARK: - Caching

    /// Small LRU cache over `ItemHeader` lookups so the list view's
    /// virtualised scroll doesn't issue a SQL query per row redraw.
    /// 5000 entries × ~250 B = ~1.2 MB — negligible.
    private let headerCache = HeaderCache(capacity: 5000)

    /// Snapshot history is read often but mutates rarely; we cache the
    /// last fetch and invalidate on import/delete.
    private var cachedHistory: [SnapshotRecord]?

    // MARK: - Lifecycle

    public init() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwinscan-scratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.blobStore = BlobStore(rootDirectory: temp)
    }

    public func attachDatabase(_ db: Database?) {
        self.database = db
        headerCache.clear()
    }

    public func attachBundle(blobsDirectory: URL) {
        self.blobStore = BlobStore(rootDirectory: blobsDirectory)
    }

    private func persistMeta<T: Encodable>(_ key: String, value: T?) {
        guard let database, let value else { return }
        do { try database.setMeta(key, value: value) }
        catch { print("[ScanStore] persistMeta(\(key)) failed: \(error)") }
    }

    public func reset() {
        categoryCounts.removeAll()
        itemCount = 0
        systemInfo = nil
        lastScanStarted = nil
        lastScanCompleted = nil
        activeSnapshotID = nil
        importingSnapshotID = nil
        importParentSnapshotID = nil
        cachedHistory = nil
        headerCache.clear()
    }

    // MARK: - Snapshot lifecycle

    /// Swap the active snapshot. Replaces the small in-memory state
    /// (categoryCounts, itemCount, systemInfo) without ever loading the
    /// items themselves — everything else is fetched lazily from SQL.
    public func setActiveSnapshot(_ snapshotID: Int64?) {
        guard let database else { return }
        headerCache.clear()
        if let snapshotID {
            let record = (try? database.allSnapshots())?.first(where: { $0.id == snapshotID })
            categoryCounts = (try? database.categoryCounts(inSnapshot: snapshotID)) ?? [:]
            itemCount = (try? database.itemCountInSnapshot(snapshotID)) ?? 0
            systemInfo = record?.systemInfo
            lastScanStarted = record?.startedAt
            lastScanCompleted = record?.importCompletedAt
            activeSnapshotID = snapshotID
        } else {
            categoryCounts = [:]
            itemCount = 0
            systemInfo = nil
            lastScanStarted = nil
            lastScanCompleted = nil
            activeSnapshotID = nil
        }
        cachedHistory = nil
    }

    /// Recompute the cached active-snapshot stats. Useful after the
    /// analyzer mutates categories under the active snapshot — re-reading
    /// counts is one SQL GROUP BY, not a full reload.
    public func refreshActiveSnapshotStats() {
        guard let database, let snapshotID = activeSnapshotID else { return }
        categoryCounts = (try? database.categoryCounts(inSnapshot: snapshotID)) ?? [:]
        itemCount = (try? database.itemCountInSnapshot(snapshotID)) ?? 0
        headerCache.clear()
    }

    @discardableResult
    public func beginImport(
        source: SnapshotSourceKind,
        sourceRef: String?,
        startedAt: Date = Date(),
        label: String? = nil,
        systemInfo: SystemInfo? = nil,
        options: ScanOptions? = nil
    ) -> Int64? {
        guard let database else { return nil }
        do {
            let parent = try database.latestSnapshotID()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let infoBytes: Data? = systemInfo.flatMap { try? encoder.encode($0) }
            let optsBytes: Data? = options.flatMap { try? encoder.encode($0) }
            let id = try database.insertSnapshot(
                parentID: parent,
                label: label,
                sourceKind: source,
                sourceRef: sourceRef,
                startedAt: startedAt,
                systemInfo: infoBytes,
                optionsJSON: optsBytes
            )
            importingSnapshotID = id
            importParentSnapshotID = parent
            activeSnapshotID = id
            categoryCounts = [:]
            itemCount = 0
            headerCache.clear()
            cachedHistory = nil
            return id
        } catch {
            print("[ScanStore] beginImport failed: \(error)")
            return nil
        }
    }

    public func completeImport(at completedAt: Date = Date()) {
        guard let database, let id = importingSnapshotID else { return }
        do { try database.markImportComplete(snapshotID: id, at: completedAt) }
        catch { print("[ScanStore] markImportComplete failed: \(error)") }
        lastScanCompleted = completedAt
        importingSnapshotID = nil
        cachedHistory = nil
        // Items have landed in the active snapshot — refresh stats so the
        // sidebar shows the post-import counts.
        refreshActiveSnapshotStats()
    }

    public func deleteSnapshot(_ snapshotID: Int64) {
        guard let database else { return }
        do { try database.deleteSnapshot(id: snapshotID) }
        catch { print("[ScanStore] deleteSnapshot failed: \(error)"); return }
        cachedHistory = nil
        if activeSnapshotID == snapshotID {
            let fallback = (try? database.latestSnapshotID()) ?? nil
            setActiveSnapshot(fallback)
        }
    }

    public func discardCurrentImport() {
        guard let id = importingSnapshotID else { return }
        deleteSnapshot(id)
        importingSnapshotID = nil
        if let parent = importParentSnapshotID {
            setActiveSnapshot(parent)
        }
    }

    public func snapshotHistory() -> [SnapshotRecord] {
        if let cachedHistory { return cachedHistory }
        guard let database else { return [] }
        let history = (try? database.allSnapshots()) ?? []
        cachedHistory = history
        return history
    }

    public func invalidateSnapshotHistory() { cachedHistory = nil }

    // MARK: - Item upsert (called from the import pipeline)

    public func upsert(_ item: ScanItem) {
        guard let database else { return }
        do { try database.upsertItem(item) }
        catch { print("[ScanStore] database.upsertItem failed: \(error)") }
        headerCache.invalidate(item.id)
    }

    /// Bulk ingest from the importer. Writes items to SQLite, records
    /// snapshot membership, and bumps the cached counts so the sidebar's
    /// per-category badges keep up during a live import.
    public func ingest(_ produced: [ScanItem]) {
        guard let database, !produced.isEmpty else { return }
        do { try database.upsertItems(produced) }
        catch { print("[ScanStore] database.upsertItems failed: \(error)") }
        if let snapshotID = importingSnapshotID {
            let ids = produced.map(\.id)
            do { try database.addItemsToSnapshot(snapshotID: snapshotID, itemIDs: ids) }
            catch { print("[ScanStore] addItemsToSnapshot failed: \(error)") }
        }
        // Incrementally bump the cached counts so the sidebar reflects the
        // import as it runs. Costs one increment per produced item — cheap
        // compared to the SQL writes that just landed.
        for item in produced {
            categoryCounts[item.category, default: 0] += 1
            itemCount += 1
            headerCache.invalidate(item.id)
        }
    }

    // MARK: - Analysis bookkeeping

    /// Apply an analyzer's output to a single item. Clears prior derived
    /// rows, writes the refined payload, updates the cached counts so the
    /// category badge moves immediately, and invalidates the header cache.
    public func applyAnalysis(_ refined: ScanItem, symbols: [SymbolRow]) {
        guard let database else { return }
        // Adjust cached counts: subtract old category, add new (we look up
        // the old header from cache or SQL).
        if let old = headerCache.get(refined.id) ?? (try? database.itemHeader(id: refined.id)) {
            if old.category != refined.category {
                categoryCounts[old.category, default: 0] -= 1
                categoryCounts[refined.category, default: 0] += 1
            }
        }
        try? database.clearAnalysisOutputForItem(refined.id)
        try? database.upsertItem(refined)
        if !symbols.isEmpty {
            try? database.insertSymbols(symbols)
        }
        headerCache.invalidate(refined.id)
    }

    public func insertSymbols(_ rows: [SymbolRow]) {
        guard !rows.isEmpty, let database else { return }
        do { try database.insertSymbols(rows) }
        catch { print("[ScanStore] insertSymbols failed: \(error)") }
    }

    public func symbols(forItem itemID: UUID) -> [SymbolRow] {
        guard let database else { return [] }
        return (try? database.symbols(forItem: itemID)) ?? []
    }

    public func symbolCount(forItem itemID: UUID) -> Int {
        guard let database else { return 0 }
        return (try? database.symbolCount(forItem: itemID)) ?? 0
    }

    public func searchSymbols(_ query: String, limit: Int = 500) -> [SymbolHit] {
        guard let database, !query.isEmpty else { return [] }
        return (try? database.searchSymbols(query: query, limit: limit)) ?? []
    }

    // MARK: - Blob access

    public func blob(forRef ref: String) -> Data? { blobStore.data(forRef: ref) }

    // MARK: - SQL-backed item access (the hot read path)

    /// Header lookup by canonical path within the active snapshot. SQL-
    /// backed via the `items_path_idx` index; used by the linked-libraries
    /// resolver in the detail view.
    public func item(atPath path: String) -> ItemHeader? {
        itemHeader(atPath: path)
    }

    public func itemHeader(atPath path: String) -> ItemHeader? {
        guard let database, let snapshotID = activeSnapshotID else { return nil }
        guard let header = try? database.itemHeader(atPath: path, inSnapshot: snapshotID) else { return nil }
        headerCache.set(header.id, header)
        return header
    }

    /// Single-header lookup. Backed by SQL via the column-only fast path,
    /// with a 5000-entry LRU cache so virtualized list scrolling doesn't
    /// pay a roundtrip per visible row.
    public func itemHeader(id: UUID) -> ItemHeader? {
        if let cached = headerCache.get(id) { return cached }
        guard let database else { return nil }
        guard let header = try? database.itemHeader(id: id) else { return nil }
        headerCache.set(id, header)
        return header
    }

    /// Bulk fetch for callers that already know which IDs they need.
    /// Drops anything already cached into the result and only SQL-fetches
    /// the misses, then warms the cache with the new entries.
    public func itemHeaders(forIDs ids: [UUID]) -> [UUID: ItemHeader] {
        guard let database, !ids.isEmpty else { return [:] }
        var out: [UUID: ItemHeader] = [:]
        out.reserveCapacity(ids.count)
        var misses: [UUID] = []
        for id in ids {
            if let cached = headerCache.get(id) {
                out[id] = cached
            } else {
                misses.append(id)
            }
        }
        if !misses.isEmpty,
           let fetched = try? database.itemHeaders(forIDs: misses) {
            for (id, h) in fetched {
                out[id] = h
                headerCache.set(id, h)
            }
        }
        return out
    }

    public func fullItem(id: UUID) -> ScanItem? {
        guard let database else { return nil }
        return try? database.item(id: id)
    }

    // MARK: - SQL-backed list queries

    /// Headers that own the given path as `owningBundlePath` in the active
    /// snapshot. SQL-backed; bounded by an index. Replaces the in-memory
    /// `itemsByOwningBundle` index (which alone consumed ~50 MB on a
    /// /System snapshot).
    public func contents(ofBundleAtPath bundlePath: String) -> [ItemHeader] {
        guard let database, let snapshotID = activeSnapshotID else { return [] }
        return (try? database.headers(inBundleAtPath: bundlePath, inSnapshot: snapshotID)) ?? []
    }

    /// Items that reference `path` via an outgoing relationship. Single
    /// SQL query with limit + count. Replaces the in-memory
    /// `pathReferencedBy` index — previously the worst memory offender
    /// (470k items × ~10 relationships = several million entries).
    public func incomingReferences(toPath path: String) -> [ItemHeader] {
        guard let database, let snapshotID = activeSnapshotID else { return [] }
        let result = (try? database.headersReferencing(path: path, inSnapshot: snapshotID, limit: 10_000))
            ?? (total: 0, headers: [])
        return result.headers
    }

    public func incomingReferencesPrefix(toPath path: String, limit: Int) -> (total: Int, items: [ItemHeader]) {
        guard let database, let snapshotID = activeSnapshotID else { return (0, []) }
        let result = (try? database.headersReferencing(path: path, inSnapshot: snapshotID, limit: limit))
            ?? (total: 0, headers: [])
        return (result.total, result.headers)
    }

    /// Stream every header in the active snapshot, optionally filtered by
    /// category. The list view uses this for its filter+sort pass without
    /// ever materialising all headers in memory. `body` returns `false` to
    /// stop the walk early.
    public func forEachHeader(
        category: ItemCategory? = nil,
        _ body: (ItemHeader) -> Bool
    ) {
        guard let database, let snapshotID = activeSnapshotID else { return }
        do {
            try database.forEachHeader(inSnapshot: snapshotID, category: category, body: body)
        } catch {
            print("[ScanStore] forEachHeader failed: \(error)")
        }
    }

    /// Stream all headers in active snapshot, no filter.
    public func forEachHeader(_ body: (ItemHeader) -> Bool) {
        forEachHeader(category: nil, body)
    }

    // MARK: - Counts façade

    public func counts() -> [ItemCategory: Int] { categoryCounts }
}

// MARK: - Header LRU cache

/// Tiny LRU cache keyed by `UUID`. Backed by a doubly-linked list inside a
/// dictionary keyed on UUID — O(1) hit/miss/insert. Synchronised via an
/// `os_unfair_lock` so concurrent reads from background tasks are safe.
/// Explicitly `nonisolated` (overriding the project default of MainActor) so
/// the nonisolated `ScanStore` can mutate it from any thread it lives on.
private nonisolated final class HeaderCache: @unchecked Sendable {
    private struct Node {
        var prev: UUID?
        var next: UUID?
        var value: ItemHeader
    }
    private var map: [UUID: Node] = [:]
    private var head: UUID?  // most recently used
    private var tail: UUID?  // least recently used
    private let capacity: Int
    private var lock = os_unfair_lock_s()

    init(capacity: Int) {
        self.capacity = capacity
        self.map.reserveCapacity(capacity + 16)
    }

    func get(_ id: UUID) -> ItemHeader? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let node = map[id] else { return nil }
        moveToFrontLocked(id, node: node)
        return node.value
    }

    func set(_ id: UUID, _ value: ItemHeader) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if var existing = map[id] {
            existing.value = value
            map[id] = existing
            moveToFrontLocked(id, node: existing)
            return
        }
        map[id] = Node(prev: nil, next: head, value: value)
        if let oldHead = head { map[oldHead]?.prev = id }
        head = id
        if tail == nil { tail = id }
        if map.count > capacity { evictTailLocked() }
    }

    func invalidate(_ id: UUID) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        removeLocked(id)
    }

    func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        map.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
    }

    private func moveToFrontLocked(_ id: UUID, node: Node) {
        guard head != id else { return }
        // Unlink
        if let prev = node.prev { map[prev]?.next = node.next }
        if let next = node.next { map[next]?.prev = node.prev }
        if tail == id { tail = node.prev }
        // Insert at head
        var updated = node
        updated.prev = nil
        updated.next = head
        map[id] = updated
        if let oldHead = head { map[oldHead]?.prev = id }
        head = id
        if tail == nil { tail = id }
    }

    private func removeLocked(_ id: UUID) {
        guard let node = map.removeValue(forKey: id) else { return }
        if let prev = node.prev { map[prev]?.next = node.next }
        if let next = node.next { map[next]?.prev = node.prev }
        if head == id { head = node.next }
        if tail == id { tail = node.prev }
    }

    private func evictTailLocked() {
        guard let id = tail else { return }
        removeLocked(id)
    }
}
