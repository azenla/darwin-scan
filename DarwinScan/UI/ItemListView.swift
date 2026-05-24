import SwiftUI
import DarwinScanCore

/// Middle column. Shows items filtered by the sidebar selection and a rich
/// search field at the top. Selection drives the detail column.
struct ItemListView: View {
    @Bindable var store: ScanStore
    var selection: SidebarSelection
    @Binding var itemSelection: UUID?

    @State private var rawSearchText: String = ""
    @State private var showHelp: Bool = false

    /// Cached filter+sort result, stored as IDs only. Recomputed by `.task`
    /// when `ListInputs` changes — *not* on row clicks. We deliberately keep
    /// only `[UUID]` here (16 B/item) rather than `[ScanItem]` (~1 KB/item):
    /// the actual item is fetched from `store.items` at row-render time, so
    /// we never carry a second full copy of the manifest in memory. On a
    /// /System "All Items" scan that's the difference between ~100 MB and
    /// ~2 MB for this view's state.
    @State private var filteredItemIDs: [UUID] = []
    @State private var displayedFilters: [SearchQuery.Filter] = []
    @State private var isRecomputing: Bool = false

    /// Active scope from the sidebar. We narrow before evaluating the query
    /// so per-item filter cost scales with the category, not the whole store.
    private var scope: ItemCategory? {
        switch selection {
        case .systemInfo:        return nil
        case .allItems:          return nil
        case .category(let c):   return c
        case .snapshot:          return nil
        }
    }

    var body: some View {
        Group {
            switch selection {
            case .systemInfo:
                ScrollView { SystemInfoView(store: store) }
            case .snapshot(let id):
                ScrollView { SnapshotDetailView(store: store, snapshotID: id) }
            default:
                VStack(spacing: 0) {
                    if !displayedFilters.isEmpty {
                        FilterChipsBar(filters: displayedFilters)
                    }
                    List(filteredItemIDs, id: \.self, selection: $itemSelection) { id in
                        if let header = store.items[id] {
                            NavigationLink(value: id) {
                                ItemRow(header: header)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .searchable(text: $rawSearchText, prompt: searchPrompt)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .task(id: ListInputs(searchText: rawSearchText,
                             selection: selection,
                             itemCount: store.items.count)) {
            await recompute()
        }
        .toolbar {
            if !title.hasPrefix("System") {
                ToolbarItem(placement: .automatic) {
                    Button { showHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .help("Search syntax help")
                    .popover(isPresented: $showHelp, arrowEdge: .top) {
                        SearchHelpPopover()
                    }
                }
            }
        }
    }

    private var searchPrompt: String {
        switch scope {
        case .none:
            return "arch:arm64 app:Mail tag:cli   — or just type"
        case .some(let c):
            return "Filter \(c.displayName)…   arch:arm64 tag:cli lang:en"
        }
    }

    private var title: String {
        switch selection {
        case .systemInfo:        return "System Info"
        case .allItems:          return "All Items"
        case .category(let c):   return c.displayName
        case .snapshot(let id):  return "Snapshot #\(id)"
        }
    }

    private var subtitle: String {
        let n = filteredItemIDs.count
        if rawSearchText.isEmpty {
            return n == 1 ? "1 item" : "\(n) items"
        }
        return n == 1 ? "1 match" : "\(n) matches"
    }

    /// Chunked: snapshot just the IDs (16 B/item), then project in 4 K-item
    /// chunks with `Task.yield()` between them so the UI stays responsive
    /// even on a /System "All Items" walk. The dict-key snapshot also makes
    /// the projection robust to scan batches mutating `store.items` during
    /// our yields — we look items up by id at use time rather than holding
    /// a live dictionary iterator across suspension points.
    ///
    /// Memory profile: the only second copy in flight is `[UUID]` (~16 B/item)
    /// plus the keyed tuple array (~64 B/item) being built. No full
    /// `[ScanItem]` snapshot is ever materialised.
    private func recompute() async {
        if case .systemInfo = selection {
            filteredItemIDs = []
            displayedFilters = []
            return
        }
        let query = SearchQuery.parse(rawSearchText)
        let scopeFilter = scope

        // Resolve FTS-backed filters (`symbol:` / `strings:`) into a Set of
        // allowed item IDs before the per-header filter pass runs. This
        // does the SQLite work once per query change instead of N times
        // per row.
        let allowedFTS: Set<UUID>? = query.resolveFTSItemIDs(against: store)

        let ids = Array(store.items.keys)
        let estimated = scopeFilter.map { store.categoryCounts[$0] ?? 0 } ?? ids.count
        var keyed: [(UUID, String, String)] = []
        keyed.reserveCapacity(estimated)

        let chunkSize = 4096
        var i = 0
        while i < ids.count {
            if Task.isCancelled { return }
            let end = min(i + chunkSize, ids.count)
            for j in i..<end {
                guard let header = store.items[ids[j]] else { continue }
                if let s = scopeFilter, header.category != s { continue }
                if let allowed = allowedFTS, !allowed.contains(header.id) { continue }
                if !query.isEmpty && !query.matches(header) { continue }
                // `lowercasedName` was pre-computed at header-build time, so
                // we don't pay a `String.lowercased()` allocation here.
                keyed.append((header.id, header.lowercasedName, header.path))
            }
            i = end
            if i < ids.count { await Task.yield() }
        }

        if Task.isCancelled { return }
        isRecomputing = true
        let toSort = keyed
        let result = await Task.detached(priority: .userInitiated) { () -> [UUID] in
            var local = toSort
            local.sort { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            }
            return local.map { $0.0 }
        }.value
        if Task.isCancelled { return }
        filteredItemIDs = result
        displayedFilters = query.filters
        isRecomputing = false
    }
}

/// Equatable bundle of the inputs that drive `filteredItems`. Used as
/// `.task(id:)` so SwiftUI cancels and re-runs the recompute exactly when
/// one of these actually changes — selection changes from row clicks are
/// not in here, which is the whole point.
private struct ListInputs: Equatable, Hashable {
    let searchText: String
    let selection: SidebarSelection
    let itemCount: Int
}

/// Horizontal strip showing the parsed filter tokens — a quick visual
/// confirmation that the search field understood what the user typed.
private struct FilterChipsBar: View {
    let filters: [SearchQuery.Filter]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(filters.enumerated()), id: \.offset) { (_, filter) in
                    HStack(spacing: 4) {
                        Image(systemName: filter.systemImage)
                            .imageScale(.small)
                        Text(filter.displayLabel)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.tint.opacity(0.18)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct SearchHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search syntax")
                .font(.headline)
            Text("Type `field:value` to add a filter. Combine multiple filters and free text — they're AND-combined. Quote values with spaces: `app:\"Time Machine\"`.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SearchHelp.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.example)
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.tint.opacity(0.14)))
                            .frame(width: 200, alignment: .leading)
                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

struct ItemRow: View {
    let header: ItemHeader

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: header.category.systemImageName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(header.name)
                        .lineLimit(1)
                    if let context = header.context, !context.isEmpty {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tint.opacity(0.12)))
                            .lineLimit(1)
                    }
                }
                Text(header.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !header.tags.isEmpty {
                TagChips(tags: Array(header.tags.prefix(3)))
            }
        }
    }
}

struct TagChips: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.18)))
            }
        }
    }
}

/// Detail view for a single snapshot row — what was captured, when, and how
/// it differs from its parent. Reached via the Snapshots sidebar section.
/// Read-only for now; switching the displayed snapshot to a historical row
/// is a follow-up that needs ScanStore.loadSnapshot wired through.
struct SnapshotDetailView: View {
    @Bindable var store: ScanStore
    let snapshotID: Int64

    var body: some View {
        let history = store.snapshotHistory()
        let record = history.first(where: { $0.id == snapshotID })
        let parent = record?.parentID.flatMap { pid in history.first(where: { $0.id == pid }) }

        VStack(alignment: .leading, spacing: 16) {
            if let record {
                snapshotCard(record: record, parent: parent)
                if let info = record.systemInfo {
                    osCard(info: info)
                }
                if let parent {
                    diffCard(current: record, parent: parent)
                }
            } else {
                ContentUnavailableView(
                    "Snapshot not found",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Snapshot #\(snapshotID) is no longer in this bundle.")
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snapshotCard(record: SnapshotRecord, parent: SnapshotRecord?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.15))
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshot #\(record.id)").font(.title2).bold()
                    Text(record.startedAt, format: .dateTime)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if record.completedAt == nil {
                        Text("In progress").font(.caption).foregroundStyle(.orange)
                    } else if let completed = record.completedAt {
                        Text("Completed \(completed, format: .dateTime)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let parent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Parent")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("#\(parent.id)")
                            .font(.callout.monospacedDigit())
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Root").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        )
    }

    private func osCard(info: SystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "macpro.gen3").foregroundStyle(.tint)
                Text("System").font(.headline)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                if let p = info.productName, let v = info.productVersion {
                    LabeledContent("OS", value: "\(p) \(v)")
                }
                if let b = info.productBuildVersion { LabeledContent("Build", value: b) }
                if let h = info.hardwareModel { LabeledContent("Model", value: h) }
                if let cpu = info.cpuBrand { LabeledContent("CPU", value: cpu) }
                if !info.architectures.isEmpty {
                    LabeledContent("Arch", value: info.architectures.joined(separator: ", "))
                }
                if let sip = info.sipStatus { LabeledContent("SIP", value: sip) }
            }
            .font(.callout)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        )
    }

    private func diffCard(current: SnapshotRecord, parent: SnapshotRecord) -> some View {
        // Compute the diff between this snapshot and its parent. Done at
        // view-render time rather than precomputed because the user may
        // never visit this card.
        let added: Int
        let removed: Int
        if let db = store.database,
           let currentSet = try? db.itemsInSnapshot(current.id),
           let parentSet = try? db.itemsInSnapshot(parent.id) {
            added = currentSet.subtracting(parentSet).count
            removed = parentSet.subtracting(currentSet).count
        } else {
            added = 0
            removed = 0
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
                Text("Diff vs Snapshot #\(parent.id)").font(.headline)
                Spacer()
            }
            HStack(spacing: 12) {
                statBadge("Added", count: added, color: .green, system: "plus.circle.fill")
                statBadge("Removed", count: removed, color: .red, system: "minus.circle.fill")
            }
            if let parentInfo = parent.systemInfo, let curInfo = current.systemInfo,
               let pV = parentInfo.productVersion, let cV = curInfo.productVersion,
               pV != cV {
                Text("OS version changed: \(pV) → \(cV)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        )
    }

    private func statBadge(_ label: String, count: Int, color: Color, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)").font(.title3.monospacedDigit()).bold()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }
}
