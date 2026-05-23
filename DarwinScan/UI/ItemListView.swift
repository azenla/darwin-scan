import SwiftUI

/// Middle column. Shows items filtered by the sidebar selection and a rich
/// search field at the top. Selection drives the detail column.
struct ItemListView: View {
    @Bindable var store: ScanStore
    var selection: SidebarSelection
    @Binding var itemSelection: UUID?

    @State private var rawSearchText: String = ""
    @State private var showHelp: Bool = false

    /// Parsed once per render — `SearchQuery.parse` is cheap (no allocations
    /// beyond the token strings) so we don't bother caching it.
    private var query: SearchQuery { SearchQuery.parse(rawSearchText) }

    /// Active scope from the sidebar. We narrow before evaluating the query
    /// so per-item filter cost scales with the category, not the whole store.
    private var scope: ItemCategory? {
        switch selection {
        case .systemInfo:        return nil
        case .allItems:          return nil
        case .category(let c):   return c
        }
    }

    private var filteredItems: [ScanItem] {
        // Start with the smallest set the sidebar narrows us to.
        let base: [ScanItem]
        if let scope {
            base = store.items(in: scope)
        } else {
            base = Array(store.items.values)
        }
        let q = query
        guard !q.isEmpty else {
            return sorted(base)
        }
        return sorted(base.filter { q.matches($0) })
    }

    /// Single-pass sort. We compare lowercased basenames once via a side
    /// dictionary so we don't pay for repeated `lowercased()` allocations
    /// during the sort's pairwise comparisons on large lists.
    private func sorted(_ items: [ScanItem]) -> [ScanItem] {
        guard items.count > 1 else { return items }
        var keyed = items.map { ($0, $0.name.lowercased(), $0.path) }
        keyed.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        return keyed.map { $0.0 }
    }

    var body: some View {
        Group {
            switch selection {
            case .systemInfo:
                ScrollView { SystemInfoView(store: store) }
            default:
                VStack(spacing: 0) {
                    if !query.filters.isEmpty {
                        FilterChipsBar(filters: query.filters)
                    }
                    List(filteredItems, selection: $itemSelection) { item in
                        NavigationLink(value: item.id) {
                            ItemRow(item: item)
                        }
                    }
                    .listStyle(.inset)
                }
                .searchable(text: $rawSearchText, prompt: searchPrompt)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
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
        let n = filteredItems.count
        if query.isEmpty {
            return n == 1 ? "1 item" : "\(n) items"
        }
        return n == 1 ? "1 match" : "\(n) matches"
    }
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
    let item: ScanItem

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: item.category.systemImageName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                    if let context = item.context, !context.isEmpty {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tint.opacity(0.12)))
                            .lineLimit(1)
                    }
                }
                Text(item.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !item.tags.isEmpty {
                TagChips(tags: Array(item.tags.prefix(3)))
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
