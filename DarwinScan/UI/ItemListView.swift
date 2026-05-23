import SwiftUI

/// Middle column. Shows items filtered by the sidebar selection and a search
/// field at the top. Sorted by name for stability; click an item to drive the
/// detail column.
struct ItemListView: View {
    @Bindable var store: ScanStore
    var selection: SidebarSelection
    @Binding var itemSelection: UUID?
    @State private var searchText: String = ""

    private var items: [ScanItem] {
        let scope: ItemCategory?
        switch selection {
        case .systemInfo: scope = nil
        case .allItems:   scope = nil
        case .category(let c): scope = c
        }
        let result: [ScanItem]
        if searchText.isEmpty {
            result = (scope.map { store.items(in: $0) } ?? Array(store.items.values))
        } else {
            result = store.search(searchText, scope: scope)
        }
        return result.sorted {
            if $0.name.lowercased() != $1.name.lowercased() {
                return $0.name.lowercased() < $1.name.lowercased()
            }
            return $0.path < $1.path
        }
    }

    var body: some View {
        Group {
            switch selection {
            case .systemInfo:
                ScrollView { SystemInfoView(store: store) }
            default:
                List(items, selection: $itemSelection) { item in
                    NavigationLink(value: item.id) {
                        ItemRow(item: item)
                    }
                }
                .listStyle(.inset)
                .searchable(text: $searchText, prompt: "Search name, path, tags, usage…")
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }

    private var title: String {
        switch selection {
        case .systemInfo:        return "System Info"
        case .allItems:          return "All Items"
        case .category(let c):   return c.displayName
        }
    }

    private var subtitle: String {
        let n = items.count
        return n == 1 ? "1 item" : "\(n) items"
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
                Text(item.name)
                    .lineLimit(1)
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
