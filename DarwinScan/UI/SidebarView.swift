import SwiftUI
import DarwinScanCore

/// Sidebar — categories, system info, and the snapshot list with per-row
/// activate / analyze / delete actions.
struct SidebarView: View {
    @Bindable var store: ScanStore
    @Binding var selection: SidebarSelection?
    var onActivateSnapshot: (Int64) -> Void = { _ in }
    var onDeleteSnapshot: (SnapshotRecord) -> Void = { _ in }
    var onAnalyzeSnapshot: (Int64) -> Void = { _ in }

    private var counts: [ItemCategory: Int] { store.counts() }

    /// Source kind of the currently-active snapshot. Drives the "System
    /// Info" vs "Build Info" rendering in the Overview and Captured
    /// sections — for an IPSW snapshot we surface build/devices instead
    /// of host metadata.
    private var activeKind: SnapshotSourceKind {
        guard let id = store.activeSnapshotID else { return .currentSystem }
        return store.snapshotHistory().first { $0.id == id }?.sourceKind ?? .currentSystem
    }

    var body: some View {
        List(selection: $selection) {
            Section("Overview") {
                NavigationLink(value: SidebarSelection.systemInfo) {
                    let isIPSW = activeKind == .ipsw
                    Label(
                        isIPSW ? "Build Info" : "System Info",
                        systemImage: isIPSW ? "shippingbox" : "info.circle"
                    )
                }
                NavigationLink(value: SidebarSelection.allItems) {
                    HStack {
                        Label("All Items", systemImage: "tray.full")
                        Spacer()
                        Text("\(store.itemCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                NavigationLink(value: SidebarSelection.fileBrowser) {
                    Label("File Browser", systemImage: "folder")
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
                        SnapshotRow(
                            record: snap,
                            isLatest: snap.id == history.first?.id,
                            isActive: snap.id == store.activeSnapshotID,
                            onActivate: { onActivateSnapshot(snap.id) },
                            onAnalyze: { onAnalyzeSnapshot(snap.id) },
                            onDelete: { onDeleteSnapshot(snap) }
                        )
                        .tag(SidebarSelection.snapshot(snap.id))
                    }
                }
            }

            if let info = store.systemInfo {
                let activeSnapshot = history.first(where: { $0.id == store.activeSnapshotID })
                let kind = activeSnapshot?.sourceKind ?? .currentSystem
                Section(kind == .ipsw ? "Build Info" : "Captured") {
                    if let v = info.productVersion {
                        LabeledContent("macOS", value: v)
                    }
                    if let b = info.productBuildVersion {
                        LabeledContent("Build", value: b)
                    }
                    if !info.architectures.isEmpty {
                        LabeledContent("Arch", value: info.architectures.joined(separator: ", "))
                    }
                    if kind == .currentSystem, let model = info.hardwareModel {
                        LabeledContent("Model", value: model)
                    }
                    if kind == .ipsw, let devices = info.supportedProductTypes, !devices.isEmpty {
                        LabeledContent("Devices", value: devices.count == 1 ? devices[0] : "\(devices.count) models")
                    }
                }
                .font(.callout)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DarwinScan")
    }
}

/// One row in the Snapshots sidebar section.
private struct SnapshotRow: View {
    let record: SnapshotRecord
    let isLatest: Bool
    let isActive: Bool
    var onActivate: () -> Void
    var onAnalyze: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: record.sourceKind.systemImageName)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .imageScale(.small)
                Text(record.label ?? "Snapshot \(record.id)")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Text("active")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.tint.opacity(0.18)))
                } else if isLatest {
                    Text("latest")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            HStack(spacing: 4) {
                analysisBadge
                if let v = record.systemInfo?.productVersion {
                    Text("· macOS \(v)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Activate") { onActivate() }
                .disabled(isActive)
            Button("Run Analysis") { onAnalyze() }
            Divider()
            Button("Delete Snapshot", role: .destructive) { onDelete() }
        }
    }

    private var analysisBadge: some View {
        let label: String
        let color: Color
        switch record.analysisState {
        case .none:     label = "not analyzed"; color = .orange
        case .pending:  label = "pending";      color = .orange
        case .running:  label = "analyzing…";   color = .blue
        case .partial:  label = "partial";      color = .yellow
        case .done:     label = "analyzed";     color = .green
        case .failed:   label = "failed";       color = .red
        }
        return Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

enum SidebarSelection: Hashable {
    case systemInfo
    case allItems
    case fileBrowser
    case category(ItemCategory)
    case snapshot(Int64)
}
