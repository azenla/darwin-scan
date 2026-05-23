import SwiftUI

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
        }
    }

    var body: some View {
        Group {
            switch selection {
            case .systemInfo:
                ScrollView { SystemInfoView(store: store) }
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
