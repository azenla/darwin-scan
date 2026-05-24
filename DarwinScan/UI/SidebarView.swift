import SwiftUI
import DarwinScanCore

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

            let history = store.snapshotHistory()
            if !history.isEmpty {
                Section("Snapshots") {
                    ForEach(history) { snap in
                        NavigationLink(value: SidebarSelection.snapshot(snap.id)) {
                            SnapshotRow(record: snap, isLatest: snap.id == history.first?.id)
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

/// One row in the Snapshots sidebar section. Shows timestamp + OS
/// version + a "latest" tag when applicable. The full diff against
/// the parent snapshot isn't computed here (would require N queries
/// at render time); the user gets that view inside the snapshot's
/// detail page.
private struct SnapshotRow: View {
    let record: SnapshotRecord
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(isLatest ? Color.accentColor : Color.secondary)
                    .imageScale(.small)
                Text(formatTimestamp(record.startedAt))
                    .font(.callout)
                Spacer()
                if isLatest {
                    Text("latest")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.tint.opacity(0.18)))
                }
            }
            if let v = record.systemInfo?.productVersion {
                Text("macOS \(v)\(record.systemInfo?.productBuildVersion.map { " (\($0))" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum SidebarSelection: Hashable {
    case systemInfo
    case allItems
    case category(ItemCategory)
    case snapshot(Int64)
}
