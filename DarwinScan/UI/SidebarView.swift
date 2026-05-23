import SwiftUI

/// Sidebar — fixed list of categories plus a "System Info" overview entry.
/// Selection is bound through to the parent's `NavigationSplitView`.
struct SidebarView: View {
    @Bindable var store: ScanStore
    @Binding var selection: SidebarSelection?

    private var counts: [ItemCategory: Int] { store.counts() }

    var body: some View {
        List(selection: $selection) {
            Section("Overview") {
                NavigationLink(value: SidebarSelection.systemInfo) {
                    Label("System Info", systemImage: "info.circle")
                }
                NavigationLink(value: SidebarSelection.allItems) {
                    HStack {
                        Label("All Items", systemImage: "tray.full")
                        Spacer()
                        Text("\(store.items.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Section("Categories") {
                ForEach(ItemCategory.allCases) { category in
                    NavigationLink(value: SidebarSelection.category(category)) {
                        HStack {
                            Label(category.displayName, systemImage: category.systemImageName)
                            Spacer()
                            Text("\(counts[category] ?? 0)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if let info = store.systemInfo {
                Section("Captured") {
                    if let v = info.productVersion {
                        LabeledContent("macOS", value: v)
                    }
                    if let b = info.productBuildVersion {
                        LabeledContent("Build", value: b)
                    }
                    if let arch = info.architectures.first {
                        LabeledContent("Arch", value: arch)
                    }
                }
                .font(.callout)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DarwinScan")
    }
}

enum SidebarSelection: Hashable {
    case systemInfo
    case allItems
    case category(ItemCategory)
}
