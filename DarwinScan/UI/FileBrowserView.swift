import SwiftUI
import AppKit
import DarwinScanCore

/// Content-column file browser. Walks the active snapshot's indexed paths as a
/// lazily-expanded directory tree and exports a selected file's captured bytes
/// out of the bundle.
///
/// The tree is kept as a **flattened array of currently-visible rows** rather
/// than a recursive node graph: expanding a directory splices its children in
/// after it, collapsing removes the contiguous deeper-depth block. That lets a
/// plain `List` virtualise the visible rows (only ~30 realised regardless of
/// how much is expanded) and keeps memory bounded — the same reason the item
/// list uses an NSTableView. Children come from
/// `ScanStore.directoryChildren(of:)`, a loose-index skip scan, so expanding a
/// wide root stays cheap.
struct FileBrowserView: View {
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    @State private var rows: [BrowserRow] = []
    @State private var selectedID: String?
    @State private var loadingPaths: Set<String> = []
    @State private var exportError: String?

    private var selectedFileHeader: ItemHeader? {
        guard let selectedID else { return nil }
        return rows.first(where: { $0.id == selectedID })?.entry.header
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.activeSnapshotID == nil {
                ContentUnavailableView(
                    "No Snapshot",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Import a snapshot to browse its files.")
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to browse",
                    systemImage: "folder",
                    description: Text("This snapshot has no indexed files.")
                )
            } else {
                List(selection: $selectedID) {
                    ForEach(rows) { row in
                        FileBrowserRow(
                            row: row,
                            isLoading: loadingPaths.contains(row.id),
                            onToggle: { toggle(row) }
                        )
                        .tag(row.id)
                        .onTapGesture(count: 2) {
                            if row.entry.isDirectory { toggle(row) }
                        }
                        .contextMenu { rowMenu(for: row) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: store.activeSnapshotID) { await reloadRoot() }
        .onChange(of: selectedID) { _, newID in
            // Selecting a file drives the shared detail column; selecting a
            // directory leaves the previous detail in place.
            if let id = newID,
               let header = rows.first(where: { $0.id == id })?.entry.header {
                itemSelection = header.id
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Header (snapshot picker + export)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .foregroundStyle(.tint)
            Picker("Snapshot", selection: snapshotBinding) {
                ForEach(store.snapshotHistory()) { snap in
                    Text(label(for: snap)).tag(Optional(snap.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            Button {
                if let header = selectedFileHeader { exportFile(header) }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedFileHeader == nil)
            .help(selectedFileHeader == nil
                  ? "Select a file to export its captured bytes."
                  : "Export the selected file from the snapshot.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var snapshotBinding: Binding<Int64?> {
        Binding(
            get: { store.activeSnapshotID },
            set: { newID in
                if let newID, newID != store.activeSnapshotID {
                    store.setActiveSnapshot(newID)
                }
            }
        )
    }

    private func label(for snap: SnapshotRecord) -> String {
        let base = snap.label ?? "Snapshot \(snap.id)"
        if let v = snap.systemInfo?.productVersion { return "\(base) · \(v)" }
        return base
    }

    @ViewBuilder
    private func rowMenu(for row: BrowserRow) -> some View {
        if let header = row.entry.header {
            Button("Export…") { exportFile(header) }
            Button("Show Details") { itemSelection = header.id; selectedID = row.id }
            Divider()
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.entry.path, forType: .string)
        }
    }

    // MARK: - Tree mutation

    private func reloadRoot() async {
        let store = self.store
        let entries = await Task.detached(priority: .userInitiated) {
            store.directoryChildren(of: "")
        }.value
        rows = entries.map { BrowserRow(entry: $0, depth: 0, isExpanded: false) }
        selectedID = nil
        loadingPaths.removeAll()
    }

    private func toggle(_ row: BrowserRow) {
        guard let idx = rows.firstIndex(where: { $0.id == row.id }) else { return }
        if rows[idx].isExpanded {
            collapse(at: idx)
        } else {
            expand(at: idx)
        }
    }

    private func collapse(at idx: Int) {
        rows[idx].isExpanded = false
        let depth = rows[idx].depth
        var end = idx + 1
        while end < rows.count && rows[end].depth > depth { end += 1 }
        if end > idx + 1 { rows.removeSubrange((idx + 1)..<end) }
    }

    private func expand(at idx: Int) {
        guard rows[idx].entry.isDirectory else { return }
        rows[idx].isExpanded = true
        let rowID = rows[idx].id
        let path = rows[idx].entry.path
        let depth = rows[idx].depth
        loadingPaths.insert(rowID)
        let store = self.store
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                store.directoryChildren(of: path)
            }.value
            loadingPaths.remove(rowID)
            // Rows may have shifted (or this directory been collapsed again)
            // while the query ran — re-find it and bail if it's no longer open.
            guard let i = rows.firstIndex(where: { $0.id == rowID }), rows[i].isExpanded else { return }
            let children = entries.map { BrowserRow(entry: $0, depth: depth + 1, isExpanded: false) }
            rows.insert(contentsOf: children, at: i + 1)
        }
    }

    // MARK: - Export

    private func exportFile(_ header: ItemHeader) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = header.name
        panel.canCreateDirectories = true
        panel.title = "Export File"
        panel.message = "Export \(header.path) from the snapshot."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = self.store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.exportItem(header, to: url)
                }.value
            } catch {
                exportError = (error as? CustomStringConvertible)?.description
                    ?? error.localizedDescription
            }
        }
    }
}

/// One flattened, currently-visible row of the browser tree.
private struct BrowserRow: Identifiable, Hashable, Sendable {
    let entry: DirectoryEntry
    let depth: Int
    var isExpanded: Bool
    var id: String { entry.id }
}

private struct FileBrowserRow: View {
    let row: BrowserRow
    let isLoading: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if row.entry.isDirectory {
                Button(action: onToggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(row.entry.name)
                    .lineLimit(1)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Color.clear.frame(width: 12, height: 1)
                Image(systemName: row.entry.header?.category.systemImageName ?? "doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(row.entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let size = row.entry.header?.size {
                    Text(ByteFormat.string(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
    }
}
