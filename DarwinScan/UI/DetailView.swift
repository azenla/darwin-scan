import SwiftUI
import AppKit
import DarwinScanCore

/// Trailing column. Renders the appropriate detail subview based on the
/// selected item's category. Heavy on stat tiles + pill chips + clickable
/// graph rows so users can navigate item ↔ item without leaving the detail
/// pane.
///
/// The list view holds only `ItemHeader` per row to keep memory bounded; the
/// detail view needs the full `ScanItem` (relationships, full executable
/// info, etc.). We fetch it from SQLite via `store.fullItem(id:)` once per
/// selection change, in a `.task(id:)` so the load doesn't run on every
/// body invalidation.
struct DetailView: View {
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    @State private var loadedItem: ScanItem?
    @State private var loadedID: UUID?

    var body: some View {
        Group {
            if let id = itemSelection, let item = loadedItem, loadedID == id {
                DetailContent(item: item, store: store, itemSelection: $itemSelection)
                    .id(id)
            } else if let id = itemSelection, let header = store.itemHeader(id: id) {
                // Selection changed but the full payload isn't loaded yet —
                // typically a single frame. Show a slim placeholder so the
                // header info doesn't pop in.
                DetailLoadingPlaceholder(header: header).id(id)
            } else {
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Pick an item from the list to see its details.")
                )
            }
        }
        .task(id: itemSelection) {
            guard let id = itemSelection else {
                loadedItem = nil
                loadedID = nil
                return
            }
            let item = store.fullItem(id: id)
            if Task.isCancelled { return }
            loadedItem = item
            loadedID = id
        }
    }
}

/// Tiny header-only stub shown for the single frame between a selection
/// change and the full payload arriving from SQLite. Mirrors the
/// `HeaderCard` layout so there's no layout jump when the full view swaps
/// in.
private struct DetailLoadingPlaceholder: View {
    let header: ItemHeader
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.15))
                    Image(systemName: header.category.systemImageName)
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(header.name).font(.title2).bold().lineLimit(2)
                    if let ctx = header.context {
                        Text(ctx).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(header.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailContent: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderCard(item: item, store: store)

                if let exec = item.executable {
                    ExecutableSection(item: item, info: exec, store: store, itemSelection: $itemSelection)
                }
                if let app = item.application {
                    AppBundleSection(item: item, info: app, store: store)
                }
                if let ls = item.launchService {
                    LaunchServiceSection(info: ls)
                }
                if let fw = item.framework {
                    FrameworkSection(info: fw)
                }
                if let model = item.mlModel {
                    MLModelSection(info: model)
                }
                if let icon = item.icon {
                    IconSection(info: icon, store: store)
                }
                if let man = item.manPage {
                    ManPageSection(item: item, info: man)
                }
                if let loc = item.localization {
                    LocalizationSection(info: loc)
                }
                if let cache = item.dyldCache {
                    DyldCacheSection(info: cache)
                }
                if let script = item.script {
                    ScriptSection(info: script)
                }
                if let plist = item.plist {
                    PlistSection(info: plist)
                }

                // Graph: outgoing relationships, contents (if a bundle),
                // and incoming references — all index-backed so they don't
                // scan the full store.
                OutgoingRelationshipsSection(item: item, store: store, itemSelection: $itemSelection)
                BundleContentsSection(item: item, store: store, itemSelection: $itemSelection)
                IncomingReferencesSection(item: item, store: store, itemSelection: $itemSelection)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(item.name)
    }
}

// MARK: - Header card

private struct HeaderCard: View {
    let item: ScanItem
    @Bindable var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                iconView
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.title2)
                            .bold()
                            .lineLimit(2)
                        Spacer()
                        CategoryBadge(category: item.category)
                    }
                    if let context = item.context {
                        Text(context)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            statTiles
            if !item.tags.isEmpty {
                ColoredTagChips(tags: item.tags)
            }
            HStack {
                Button {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    let controller = ScanController()
                    controller.analyzeItem(item.id, options: store.options, in: store)
                    if let active = store.activeSnapshotID { store.setActiveSnapshot(active) }
                } label: {
                    Label(item.analysisState == .done ? "Re-Analyze" : "Analyze", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Run analysis on just this item — useful when developing new inspectors.")
                if item.fileBlobRef != nil {
                    Button {
                        exportItem()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Export this file's captured bytes out of the bundle.")
                }
                Spacer()
                AnalysisStateChip(state: item.analysisState, analyzedAt: item.analyzedAt)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        )
    }

    private func exportItem() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        panel.title = "Export File"
        panel.message = "Export \(item.path) from the snapshot."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = self.store
        let header = ItemHeader(from: item)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.exportItem(header, to: url)
                }.value
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Export failed"
                alert.informativeText = (error as? CustomStringConvertible)?.description
                    ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    @ViewBuilder private var iconView: some View {
        // App icons live in the blob store under appicon-* refs; show them
        // when present. Otherwise fall back to the category's SF Symbol.
        if let ref = item.application?.iconRef,
           let data = store.blob(forRef: ref),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else if let ref = item.icon?.previewBlobRef,
                  let data = store.blob(forRef: ref),
                  let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.tint.opacity(0.15))
                Image(systemName: item.category.systemImageName)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
            }
            .frame(width: 64, height: 64)
        }
    }

    private var statTiles: some View {
        HStack(spacing: 10) {
            StatTile(systemImage: "scalemass", label: "Size", value: ByteFormat.string(item.size))
            if let mtime = item.modifiedAt {
                StatTile(systemImage: "clock", label: "Modified", value: ByteFormat.compactDate(mtime))
            }
            if let sha = item.sha256 {
                StatTile(systemImage: "number", label: "SHA-256", value: String(sha.prefix(10)) + "…", monospaced: true, textSelectable: true, selectableValue: sha)
            }
        }
    }
}

private struct CategoryBadge: View {
    let category: ItemCategory
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.systemImageName)
                .imageScale(.small)
            Text(category.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.tint.opacity(0.18)))
    }
}

/// Small chip near the detail header showing whether the item has been
/// analyzed (and when). Color matches the sidebar's snapshot row badge.
struct AnalysisStateChip: View {
    let state: AnalysisState
    let analyzedAt: Date?

    var body: some View {
        let (label, color): (String, Color) = {
            switch state {
            case .pending: return ("Pending Analysis", .orange)
            case .running: return ("Analyzing…", .blue)
            case .done:    return ("Analyzed", .green)
            case .failed:  return ("Analysis Failed", .red)
            case .none, .partial: return ("Partial", .yellow)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: state == .done ? "checkmark.seal" : "clock.badge.questionmark")
                .imageScale(.small)
            Text(label)
                .font(.caption2)
            if state == .done, let analyzedAt {
                Text("· \(ByteFormat.compactDate(analyzedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct StatTile: View {
    let systemImage: String
    let label: String
    let value: String
    var monospaced: Bool = false
    var textSelectable: Bool = false
    /// When the displayed value is truncated for the tile, expose the full
    /// value to clipboard selection without showing it.
    var selectableValue: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Group {
                    if monospaced {
                        Text(value).font(.system(.callout, design: .monospaced))
                    } else {
                        Text(value).font(.callout)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .modifier(SelectableIfNeeded(text: textSelectable ? (selectableValue ?? value) : nil))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.07))
        )
    }
}

private struct SelectableIfNeeded: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text {
            content.textSelection(.enabled).help(text)
        } else {
            content
        }
    }
}

// MARK: - Section card (shared shell)

private struct Section<Content: View>: View {
    let title: String
    let systemImage: String
    var accessory: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .imageScale(.medium)
                Text(title)
                    .font(.headline)
                if let accessory {
                    Text(accessory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.14)))
                }
                Spacer()
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        )
    }
}

/// Key-value row used inside `Section`. Right-aligned value, label kept
/// narrow so multiple rows align cleanly.
private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Group {
                if monospaced {
                    Text(value).font(.system(.callout, design: .monospaced))
                } else {
                    Text(value).font(.callout)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Per-category sections

private struct ExecutableSection: View {
    let item: ScanItem
    let info: ExecutableInfo
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        Section(title: "Executable", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                // Architectures get their own colorful row of chips up top.
                if !info.architectures.isEmpty {
                    HStack(spacing: 6) {
                        Text("Architectures")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        WrappingHStack(spacing: 6) {
                            ForEach(info.architectures, id: \.self) { arch in
                                ColoredChip(text: arch, color: archColor(arch))
                            }
                            if info.isFatBinary {
                                ColoredChip(text: "fat / universal", color: .teal)
                            }
                        }
                    }
                }
                InfoRow(label: "Kind", value: info.kind.rawValue.capitalized)
                if let platform = info.platform {
                    InfoRow(label: "Platform", value: platform)
                }
                if let minOS = info.minOS {
                    InfoRow(label: "Min OS", value: minOS)
                }
                if let sdk = info.sdkVersion {
                    InfoRow(label: "SDK", value: sdk)
                }
                if !info.roles.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Roles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        WrappingHStack(spacing: 6) {
                            ForEach(info.roles, id: \.self) { role in
                                ColoredChip(text: role.rawValue, color: roleColor(role))
                            }
                        }
                    }
                }
                if let usage = info.usageLine {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(usage)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 12) {
                    if info.isApple {
                        ColoredChip(text: "Apple-shipped", color: .red)
                    } else {
                        ColoredChip(text: "Third-party", color: .orange)
                    }
                    if info.isCrossPlatformTool {
                        ColoredChip(text: "Cross-platform", color: .yellow)
                    }
                    if info.isHardenedRuntime {
                        ColoredChip(text: "Hardened runtime", color: .indigo)
                    }
                }
                if let signing = info.signingIdentifier {
                    InfoRow(label: "Signed as", value: signing, monospaced: true)
                }
                if let team = info.teamIdentifier {
                    InfoRow(label: "Team ID", value: team, monospaced: true)
                }
            }
        }
        if !info.linkedLibraries.isEmpty {
            Section(
                title: "Linked Libraries",
                systemImage: "link",
                accessory: "\(info.linkedLibraries.count)"
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(info.linkedLibraries, id: \.self) { lib in
                        LinkedLibraryRow(lib: lib, sourceItem: item, store: store, itemSelection: $itemSelection)
                    }
                }
            }
        }
        if !info.rpaths.isEmpty {
            Section(title: "RPATHs", systemImage: "arrow.triangle.branch", accessory: "\(info.rpaths.count)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(info.rpaths, id: \.self) { rp in
                        Text(rp)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        if let ref = info.stringsBlobRef, let data = store.blob(forRef: ref),
           let text = String(data: data, encoding: .utf8) {
            Section(
                title: "Strings",
                systemImage: "doc.text.below.ecg",
                accessory: ByteFormat.string(Int64(data.count))
            ) {
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
        }

        SymbolsSubsection(item: item, store: store)
    }
}

/// Symbols extracted by `SymbolInspector`, grouped by kind with a live
/// substring filter. Heavy lifting (the `symbols(forItem:)` SQLite read)
/// happens in `.task(id:)` so it doesn't run on every body invalidation —
/// the selection change is the only trigger.
private struct SymbolsSubsection: View {
    let item: ScanItem
    @Bindable var store: ScanStore

    @State private var rows: [SymbolRow] = []
    @State private var loadedID: UUID?
    @State private var filter: String = ""

    var body: some View {
        if rows.isEmpty && loadedID == item.id {
            EmptyView()
        } else {
            let totalsByKind = Dictionary(grouping: rows, by: { $0.kind }).mapValues(\.count)
            let total = rows.count
            let filtered = applyFilter(filter, to: rows)
            Section(
                title: "Symbols",
                systemImage: "function",
                accessory: total > 0 ? "\(total)" : nil
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if total == 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        // Per-kind count chips. Click a chip to filter to
                        // that kind (toggle behaviour).
                        WrappingHStack(spacing: 6) {
                            ForEach(orderedKinds(in: totalsByKind), id: \.self) { kind in
                                ColoredChip(
                                    text: "\(kind.displayName): \(totalsByKind[kind] ?? 0)",
                                    color: kindColor(kind)
                                )
                            }
                        }
                        TextField("Filter symbols (substring)…", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        if filtered.isEmpty {
                            Text("No matches").font(.caption).foregroundStyle(.secondary)
                        } else {
                            // Cap visible rows so a 50k-symbol binary doesn't
                            // explode SwiftUI's layout time.
                            let visible = Array(filtered.prefix(200))
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(visible, id: \.self) { row in
                                    HStack(spacing: 6) {
                                        Image(systemName: kindIcon(row.kind))
                                            .foregroundStyle(kindColor(row.kind))
                                            .imageScale(.small)
                                            .frame(width: 14)
                                        Text(row.name)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                }
                            }
                            if filtered.count > visible.count {
                                Text("…\(filtered.count - visible.count) more (refine the filter to narrow)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .task(id: item.id) {
                let id = item.id
                if loadedID == id { return }
                let loaded = await Task.detached(priority: .userInitiated) {
                    await store.symbols(forItem: id)
                }.value
                if Task.isCancelled { return }
                rows = loaded
                loadedID = id
            }
        }
    }

    private func applyFilter(_ query: String, to rows: [SymbolRow]) -> [SymbolRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(q) }
    }

    private func orderedKinds(in map: [SymbolRow.Kind: Int]) -> [SymbolRow.Kind] {
        let order: [SymbolRow.Kind] = [
            .function, .data, .objcClass, .objcMetaClass, .objcProtocol,
            .swiftClass, .swiftStruct, .undefined
        ]
        return order.filter { map[$0] != nil }
    }

    private func kindColor(_ k: SymbolRow.Kind) -> Color {
        switch k {
        case .function:      return .green
        case .data:          return .blue
        case .objcClass:     return .purple
        case .objcMetaClass: return .indigo
        case .objcProtocol:  return .pink
        case .swiftClass:    return .orange
        case .swiftStruct:   return .yellow
        case .undefined:     return .gray
        }
    }

    private func kindIcon(_ k: SymbolRow.Kind) -> String {
        switch k {
        case .function:      return "f.cursive"
        case .data:          return "tablecells"
        case .objcClass:     return "c.circle"
        case .objcMetaClass: return "c.circle.fill"
        case .objcProtocol:  return "p.circle"
        case .swiftClass:    return "swift"
        case .swiftStruct:   return "shippingbox"
        case .undefined:     return "questionmark.circle"
        }
    }
}

private extension SymbolRow.Kind {
    var displayName: String {
        switch self {
        case .function:      return "fn"
        case .data:          return "data"
        case .objcClass:     return "objc class"
        case .objcMetaClass: return "objc meta"
        case .objcProtocol:  return "objc proto"
        case .swiftClass:    return "swift class"
        case .swiftStruct:   return "swift struct"
        case .undefined:     return "imported"
        }
    }
}

/// One row inside the Linked Libraries list. Tries hard to resolve the
/// linked path against an item in this scan so the row becomes clickable:
///
/// 1. Direct match: `store.item(atPath: "/usr/lib/libSystem.B.dylib")`.
/// 2. `@rpath/Foo.framework/Foo` — substitute each of the binary's rpaths
///    (`info.rpaths`) for `@rpath`, query the store, return the first hit.
/// 3. `@executable_path/...` / `@loader_path/...` — substitute the
///    containing directory of the source binary.
/// 4. `@rpath/.../Versions/A/Foo` — Apple framework dylibs are often loaded
///    via the versioned interior path; we also try the un-versioned form.
///
/// When all four fail (common for dyld_shared_cache-resident dylibs that
/// have no on-disk file in this scan), the row renders dimly without a
/// click target — same as before, but the failure rate drops sharply.
private struct LinkedLibraryRow: View {
    let lib: String
    let sourceItem: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?
    // Resolved off the body pass (in `.task`) so a binary linking many dylibs
    // doesn't fire N blocking @rpath-resolution SQL lookups during layout.
    @State private var target: ItemHeader?
    var body: some View {
        Group {
            if let target {
                Button {
                    itemSelection = target.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.circle.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                        Text(lib)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let ctx = target.context {
                            Text(ctx)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                    Text(lib)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
        }
        .task(id: lib) {
            target = resolve(lib, source: sourceItem, store: store)
        }
    }

    private func resolve(_ rawPath: String, source: ScanItem, store: ScanStore) -> ItemHeader? {
        // 1. Direct match.
        if let h = store.item(atPath: rawPath) { return h }

        // 2. @rpath substitution.
        if rawPath.hasPrefix("@rpath/") {
            let tail = String(rawPath.dropFirst("@rpath/".count))
            for rpath in source.executable?.rpaths ?? [] {
                let expanded: String
                if rpath.hasPrefix("@executable_path/") {
                    let base = source.path as NSString
                    expanded = base.deletingLastPathComponent + "/" + String(rpath.dropFirst("@executable_path/".count)) + "/" + tail
                } else if rpath.hasPrefix("@loader_path/") {
                    let base = source.path as NSString
                    expanded = base.deletingLastPathComponent + "/" + String(rpath.dropFirst("@loader_path/".count)) + "/" + tail
                } else {
                    expanded = rpath + "/" + tail
                }
                let normalized = (expanded as NSString).standardizingPath
                if let h = store.item(atPath: normalized) { return h }
            }
        }

        // 3. @executable_path / @loader_path substitution.
        if rawPath.hasPrefix("@executable_path/") || rawPath.hasPrefix("@loader_path/") {
            let dirURL = URL(fileURLWithPath: source.path).deletingLastPathComponent()
            let tail: String
            if rawPath.hasPrefix("@executable_path/") {
                tail = String(rawPath.dropFirst("@executable_path/".count))
            } else {
                tail = String(rawPath.dropFirst("@loader_path/".count))
            }
            let expanded = dirURL.appendingPathComponent(tail).path
            let normalized = (expanded as NSString).standardizingPath
            if let h = store.item(atPath: normalized) { return h }
        }

        return nil
    }
}

private struct AppBundleSection: View {
    let item: ScanItem
    let info: AppBundleInfo
    @Bindable var store: ScanStore
    var body: some View {
        Section(title: "Application", systemImage: "app.dashed") {
            VStack(alignment: .leading, spacing: 6) {
                if let id = info.bundleIdentifier { InfoRow(label: "Bundle ID", value: id) }
                if let v = info.shortVersionString {
                    InfoRow(label: "Version", value: v + (info.bundleVersion.map { " (\($0))" } ?? ""))
                }
                if let exec = info.executableName { InfoRow(label: "Executable", value: exec) }
                if let category = info.category { InfoRow(label: "Category", value: category) }
                if let minSys = info.minimumSystemVersion { InfoRow(label: "Min macOS", value: minSys) }
                if !info.urlSchemes.isEmpty {
                    InfoRow(label: "URL Schemes", value: info.urlSchemes.joined(separator: ", "))
                }
                HStack(spacing: 8) {
                    if info.isHidden { ColoredChip(text: "Hidden (LSUIElement)", color: .purple) }
                    if info.isAgentApp { ColoredChip(text: "Background-only", color: .indigo) }
                }
            }
        }
    }
}

private struct LaunchServiceSection: View {
    let info: LaunchServiceInfo
    var body: some View {
        Section(
            title: info.kind == .daemon ? "Launch Daemon" : "Launch Agent",
            systemImage: "gearshape.2"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let label = info.label { InfoRow(label: "Label", value: label, monospaced: true) }
                if let program = info.program { InfoRow(label: "Program", value: program, monospaced: true) }
                if !info.programArguments.isEmpty {
                    InfoRow(label: "Arguments", value: info.programArguments.joined(separator: " "), monospaced: true)
                }
                HStack(spacing: 8) {
                    if info.runAtLoad { ColoredChip(text: "RunAtLoad", color: .orange) }
                    if info.keepAlive { ColoredChip(text: "KeepAlive", color: .red) }
                    if info.disabled  { ColoredChip(text: "Disabled",  color: .gray) }
                    if let interval = info.startInterval {
                        ColoredChip(text: "Every \(interval)s", color: .blue)
                    }
                }
                if !info.machServices.isEmpty {
                    InfoRow(label: "MachServices", value: info.machServices.joined(separator: ", "), monospaced: true)
                }
                if !info.watchPaths.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("WatchPaths")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(info.watchPaths, id: \.self) { p in
                                Text(p).font(.system(.caption, design: .monospaced))
                            }
                        }
                        Spacer()
                    }
                }
                if let user = info.userName { InfoRow(label: "UserName", value: user) }
            }
        }
    }
}

private struct FrameworkSection: View {
    let info: FrameworkInfo
    var body: some View {
        Section(
            title: info.isPrivate ? "Private Framework" : "Framework / Library",
            systemImage: "shippingbox"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let id = info.bundleIdentifier { InfoRow(label: "Bundle ID", value: id) }
                if let v = info.shortVersionString { InfoRow(label: "Version", value: v) }
                if let curr = info.currentVersion { InfoRow(label: "Current Version", value: curr) }
                if let exec = info.executableName { InfoRow(label: "Executable", value: exec) }
                if info.headerCount > 0 { InfoRow(label: "Public Headers", value: "\(info.headerCount)") }
                if info.isPrivate {
                    HStack { ColoredChip(text: "Private", color: .purple); Spacer() }
                }
            }
        }
    }
}

private struct MLModelSection: View {
    let info: MLModelInfo
    var body: some View {
        Section(title: "Machine Learning Model", systemImage: "brain") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Container", value: info.container.rawValue)
                if let t = info.modelType { InfoRow(label: "Type", value: t) }
                if let desc = info.modelDescription { InfoRow(label: "Description", value: desc) }
                if let author = info.author { InfoRow(label: "Author", value: author) }
                if let lic = info.license { InfoRow(label: "License", value: lic) }
                if let labels = info.classLabelsCount { InfoRow(label: "Class Labels", value: "\(labels)") }
                if !info.inputs.isEmpty { InfoRow(label: "Inputs", value: info.inputs.joined(separator: ", ")) }
                if !info.outputs.isEmpty { InfoRow(label: "Outputs", value: info.outputs.joined(separator: ", ")) }
            }
        }
    }
}

private struct IconSection: View {
    let info: IconInfo
    @Bindable var store: ScanStore
    var body: some View {
        Section(title: "Icon", systemImage: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Kind", value: info.kind.rawValue)
                if !info.representations.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Representations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        WrappingHStack(spacing: 4) {
                            ForEach(info.representations, id: \.self) { rep in
                                Text(rep)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.secondary.opacity(0.14)))
                            }
                        }
                    }
                }
                if let ref = info.previewBlobRef, let data = store.blob(forRef: ref), let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 256, maxHeight: 256)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct ManPageSection: View {
    let item: ScanItem
    let info: ManPageInfo
    @State private var renderedText: String? = nil
    var body: some View {
        Section(title: "Man Page", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 6) {
                if let s = info.section { InfoRow(label: "Section", value: s) }
                if let t = info.title { InfoRow(label: "Title", value: t) }
                if let d = info.description { InfoRow(label: "Synopsis", value: d) }
                if info.compressed {
                    HStack { ColoredChip(text: "gzip", color: .teal); Spacer() }
                }
                Divider().padding(.vertical, 4)
                if let text = renderedText {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 360)
                } else {
                    Button("Render Source") {
                        if let (_, text) = ManPageInspector.inspect(url: URL(fileURLWithPath: item.path)) {
                            renderedText = text
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct LocalizationSection: View {
    let info: LocalizationInfo
    var body: some View {
        Section(title: "Localization", systemImage: "character.bubble") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Kind", value: info.kind.rawValue)
                if let lang = info.language { InfoRow(label: "Language", value: lang) }
                if let count = info.keyCount { InfoRow(label: "Keys", value: "\(count)") }
                if let id = info.owningBundleId { InfoRow(label: "Owning Bundle", value: id) }
            }
        }
    }
}

private struct DyldCacheSection: View {
    let info: DyldCacheInfo
    var body: some View {
        Section(title: "DYLD Shared Cache", systemImage: "cylinder.split.1x2") {
            VStack(alignment: .leading, spacing: 6) {
                if let arch = info.architecture {
                    HStack(spacing: 8) {
                        Text("Architecture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        ColoredChip(text: arch, color: archColor(arch))
                        Spacer()
                    }
                }
                if let v = info.formatVersion { InfoRow(label: "Format Magic", value: v, monospaced: true) }
                if let n = info.imageCount { InfoRow(label: "Images", value: "\(n)") }
                if let m = info.mappingCount { InfoRow(label: "Mappings", value: "\(m)") }
                if let s = info.subCacheCount, s > 0 {
                    InfoRow(label: "Subcaches", value: "\(s)")
                }
            }
        }
    }
}

private struct ScriptSection: View {
    let info: ScriptInfo
    var body: some View {
        Section(title: "Script", systemImage: "scroll") {
            VStack(alignment: .leading, spacing: 6) {
                if let interp = info.interpreter { InfoRow(label: "Interpreter", value: interp, monospaced: true) }
                if let lang = info.language {
                    HStack(spacing: 8) {
                        Text("Language")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        ColoredChip(text: lang, color: .yellow)
                        Spacer()
                    }
                }
            }
        }
    }
}

private struct PlistSection: View {
    let info: PlistInfo
    var body: some View {
        Section(title: "Plist", systemImage: "list.bullet.indent") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ColoredChip(text: info.kind.rawValue, color: plistKindColor(info.kind))
                    ColoredChip(text: info.format.rawValue, color: formatColor(info.format))
                    ColoredChip(text: info.topLevel.rawValue, color: .gray)
                    if info.looksLikeInfoPlist {
                        ColoredChip(text: "bundle metadata", color: .green)
                    }
                    Spacer()
                }
                if let n = info.keyCount {
                    InfoRow(label: "Keys", value: "\(n)")
                }
                if let n = info.elementCount {
                    InfoRow(label: "Elements", value: "\(n)")
                }
                if let preview = info.previewText, !preview.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Preview")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        ScrollView {
                            Text(preview)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    }
                }
            }
        }
    }

    private func plistKindColor(_ k: PlistInfo.Kind) -> Color {
        switch k {
        case .info:           return .green
        case .version:        return .mint
        case .launchService:  return .orange
        case .preference:     return .blue
        case .entitlements:   return .red
        case .mappedTypes:    return .purple
        case .other:          return .gray
        }
    }
    private func formatColor(_ f: PlistInfo.Format) -> Color {
        switch f {
        case .xml:     return .blue
        case .binary:  return .teal
        case .json:    return .yellow
        case .unknown: return .gray
        }
    }
}

// MARK: - Graph sections (outgoing / contents / incoming)

private struct OutgoingRelationshipsSection: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?
    var body: some View {
        let grouped = Dictionary(grouping: item.relationships, by: { $0.kind })
        // linksDylib is already rendered as its own Linked Libraries section
        // above, so we don't double-up here.
        let kindsToShow: [Relationship.Kind] = [.containsExecutable, .ownedByBundle, .launchesProgram, .sameBundle, .inDyldCache]
        ForEach(kindsToShow, id: \.self) { kind in
            if let rels = grouped[kind], !rels.isEmpty {
                Section(
                    title: title(for: kind),
                    systemImage: systemImage(for: kind),
                    accessory: rels.count > 1 ? "\(rels.count)" : nil
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rels.enumerated()), id: \.offset) { (_, rel) in
                            RelationshipRow(rel: rel, store: store, itemSelection: $itemSelection)
                        }
                    }
                }
            }
        }
    }

    private func title(for kind: Relationship.Kind) -> String {
        switch kind {
        case .linksDylib:         return "Links"
        case .ownedByBundle:      return "Inside Bundle"
        case .launchesProgram:    return "Launches"
        case .sameBundle:         return "Bundle Siblings"
        case .inDyldCache:        return "In DYLD Cache"
        case .containsImage:      return "Cached Images"
        case .containsExecutable: return "Main Executable"
        }
    }
    private func systemImage(for kind: Relationship.Kind) -> String {
        switch kind {
        case .linksDylib:         return "link"
        case .ownedByBundle:      return "shippingbox"
        case .launchesProgram:    return "play.fill"
        case .sameBundle:         return "square.stack.3d.up"
        case .inDyldCache:        return "cylinder.split.1x2"
        case .containsImage:      return "shippingbox.fill"
        case .containsExecutable: return "terminal"
        }
    }
}

/// Items that live inside this bundle. Only shown for bundle-shaped items
/// (their path matches another item's `owningBundlePath`). Index-backed —
/// `itemsByOwningBundle` makes this O(1) instead of an O(N) filter.
private struct BundleContentsSection: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        let contents = store.contents(ofBundleAtPath: item.path)
        if contents.isEmpty {
            EmptyView()
        } else {
            Section(
                title: "Contents",
                systemImage: "square.stack.3d.up",
                accessory: "\(contents.count)"
            ) {
                let buckets = Dictionary(grouping: contents, by: { $0.category })
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ItemCategory.allCases) { cat in
                        if let bucket = buckets[cat], !bucket.isEmpty {
                            BundleContentsBucket(
                                category: cat,
                                items: bucket,
                                store: store,
                                itemSelection: $itemSelection
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct BundleContentsBucket: View {
    let category: ItemCategory
    let items: [ItemHeader]
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    @State private var expanded: Bool = false
    private let collapsedLimit = 6

    var body: some View {
        let sorted = items.sorted { $0.lowercasedName < $1.lowercasedName }
        let visible = expanded ? sorted : Array(sorted.prefix(collapsedLimit))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: category.systemImageName)
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                Text(category.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(sorted.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(visible, id: \.id) { child in
                Button {
                    itemSelection = child.id
                } label: {
                    HStack(spacing: 6) {
                        Text(child.name)
                            .font(.callout)
                        if let ctx = child.context {
                            Text(ctx)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            if sorted.count > collapsedLimit {
                Button(expanded ? "Show less" : "Show all \(sorted.count)") {
                    expanded.toggle()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct IncomingReferencesSection: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        let (total, incoming) = store.incomingReferencesPrefix(toPath: item.path, limit: 64)
        if total == 0 {
            EmptyView()
        } else {
            Section(
                title: "Referenced By",
                systemImage: "arrow.turn.up.left",
                accessory: "\(total)"
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(incoming, id: \.id) { ref in
                        Button {
                            itemSelection = ref.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: ref.category.systemImageName)
                                    .foregroundStyle(.tint)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(ref.name)
                                        if let ctx = ref.context {
                                            Text(ctx).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(ref.path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if total > incoming.count {
                        Text("…\(total - incoming.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct RelationshipRow: View {
    let rel: Relationship
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?
    // Resolved off the synchronous body pass (in `.task`) so opening a detail
    // view with many relationships doesn't fire N blocking SQL lookups during
    // layout. Until it resolves the row shows the raw path.
    @State private var target: ItemHeader?
    var body: some View {
        HStack(spacing: 6) {
            if let target {
                Button {
                    itemSelection = target.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: target.category.systemImageName)
                            .foregroundStyle(.tint)
                            .frame(width: 14)
                        Text(target.name)
                        if let ctx = target.context {
                            Text("·").foregroundStyle(.tertiary)
                            Text(ctx).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.tertiary)
                    Text(rel.targetPath)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let note = rel.note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .task(id: rel.targetPath) {
            target = store.item(atPath: rel.targetPath)
        }
    }
}

// MARK: - Chips

/// Coloured tag chip. Tags that map to a known semantic (architectures,
/// platforms, roles) get a meaningful colour; everything else falls back to
/// neutral grey. Keeps the row vertically aligned with `WrappingHStack`.
private struct ColoredTagChips: View {
    let tags: [String]
    var body: some View {
        WrappingHStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                ColoredChip(text: tag, color: tagColor(tag))
            }
        }
    }
}

private struct ColoredChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

private func archColor(_ arch: String) -> Color {
    let lower = arch.lowercased()
    if lower.hasPrefix("arm64")  { return .green }
    if lower.hasPrefix("x86_64") { return .blue }
    if lower.hasPrefix("arm")    { return .mint }
    if lower.hasPrefix("i386")   { return .orange }
    return .gray
}

private func roleColor(_ role: ExecutableInfo.Role) -> Color {
    switch role {
    case .cli:         return .orange
    case .daemon:      return .red
    case .agent:       return .pink
    case .helper:      return .purple
    case .library:     return .blue
    case .interpreter: return .yellow
    case .gui:         return .indigo
    case .unknown:     return .gray
    }
}

private func tagColor(_ tag: String) -> Color {
    let lower = tag.lowercased()
    if let arch = ["arm64", "arm64e", "x86_64", "x86_64h", "i386", "arm", "arm64_32"].first(where: { lower == $0 }) {
        return archColor(arch)
    }
    if ["macos", "ios", "tvos", "watchos", "visionos", "maccatalyst", "driverkit", "bridgeos"].contains(lower) {
        return .indigo
    }
    if ["cli", "daemon", "agent", "helper", "library", "interpreter"].contains(lower) {
        return .orange
    }
    if lower == "fat" { return .teal }
    if lower == "cross-platform" { return .yellow }
    if lower == "third-party" { return .red }
    if lower == "private" || lower == "private-framework" { return .purple }
    if lower == "hidden" || lower == "background-only" { return .indigo }
    if lower == "dyld-cache" { return .blue }
    if lower == "executable" { return .green }
    if lower == "dylib" || lower == "bundle" { return .blue }
    if lower == "kext" { return .purple }
    if lower == "framework" { return .blue }
    if lower == "ml" { return .pink }
    if lower == "app" { return .green }
    if lower == "lproj" || lower == "strings" || lower == "stringsdict" { return .cyan }
    if lower == "man" { return .brown }
    return .gray
}

// MARK: - WrappingHStack (poor man's flow layout)

/// Lightweight wrapping HStack — enough for chip rows without pulling in a
/// full layout. SwiftUI's native `Layout` protocol would be the proper home
/// for this; for our needs the simpler GeometryReader-based pattern is fine.
private struct WrappingHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > containerWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: containerWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        let containerWidth = bounds.width
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + containerWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - System info overview

struct SystemInfoView: View {
    @Bindable var store: ScanStore

    private var activeRecord: SnapshotRecord? {
        guard let id = store.activeSnapshotID else { return nil }
        return store.snapshotHistory().first { $0.id == id }
    }

    var body: some View {
        let kind = activeRecord?.sourceKind ?? .currentSystem
        VStack(alignment: .leading, spacing: 16) {
            if let info = store.systemInfo {
                switch kind {
                case .currentSystem:
                    hostSection(info)
                case .ipsw:
                    buildInfoSection(info, record: activeRecord)
                }
                if let kv = info.kernelVersion, kind == .currentSystem {
                    Section(title: "Kernel", systemImage: "cpu") {
                        Text(kv)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let boot = info.bootArgs, !boot.isEmpty, kind == .currentSystem {
                    Section(title: "Boot Args", systemImage: "power") {
                        Text(boot)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No system info yet",
                    systemImage: "info.circle",
                    description: Text("Import a snapshot to capture host or IPSW info.")
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hostSection(_ info: SystemInfo) -> some View {
        Section(title: "Host", systemImage: "macpro.gen3") {
            VStack(alignment: .leading, spacing: 6) {
                if let p = info.productName, let v = info.productVersion {
                    InfoRow(label: "OS", value: "\(p) \(v)")
                }
                if let b = info.productBuildVersion { InfoRow(label: "Build", value: b) }
                if let h = info.hardwareModel { InfoRow(label: "Model", value: h) }
                if let cpu = info.cpuBrand { InfoRow(label: "CPU", value: cpu) }
                if !info.architectures.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Arch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        WrappingHStack(spacing: 6) {
                            ForEach(info.architectures, id: \.self) { arch in
                                ColoredChip(text: arch, color: archColor(arch))
                            }
                        }
                    }
                }
                if let host = info.hostName { InfoRow(label: "Hostname", value: host) }
                if let sip = info.sipStatus { InfoRow(label: "SIP", value: sip) }
                InfoRow(label: "Captured", value: ByteFormat.compactDate(info.capturedAt))
            }
        }
    }

    @ViewBuilder
    private func buildInfoSection(_ info: SystemInfo, record: SnapshotRecord?) -> some View {
        // The "System Info" sidebar selection, when the active snapshot is
        // an IPSW, becomes a Build Info dashboard for that image. The
        // header surfaces the image name (e.g. "Image #1 · UniversalMac…")
        // so it's obvious which build the panel describes.
        Section(title: "Build Info" + (record.map { " · \(label(for: $0))" } ?? ""),
                systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 6) {
                if let v = info.productVersion {
                    InfoRow(label: "macOS", value: v)
                }
                if let b = info.productBuildVersion { InfoRow(label: "Build", value: b) }
                if let train = info.buildTrain { InfoRow(label: "Train", value: train) }
                if !info.architectures.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Arch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        WrappingHStack(spacing: 6) {
                            ForEach(info.architectures, id: \.self) { arch in
                                ColoredChip(text: arch, color: archColor(arch))
                            }
                        }
                    }
                }
                if let source = record?.sourceRef {
                    InfoRow(label: "Source", value: source)
                }
                if let started = record?.startedAt {
                    InfoRow(label: "Imported", value: ByteFormat.compactDate(started))
                }
            }
        }
        if let devices = info.supportedProductTypes, !devices.isEmpty {
            Section(title: "Supported Devices · \(devices.count)", systemImage: "macbook.and.iphone") {
                WrappingHStack(spacing: 6) {
                    ForEach(devices, id: \.self) { device in
                        Text(device)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.12)))
                    }
                }
            }
        }
    }

    private func label(for record: SnapshotRecord) -> String {
        // "Image #N" if the snapshot has no friendly label; otherwise the
        // friendly label produced by the source provider (e.g.
        // "IPSW · UniversalMac_26.5_25F71_Restore" → strip the prefix so
        // the header line stays short).
        if let lbl = record.label {
            if lbl.hasPrefix("IPSW · ") { return "Image #\(record.id) · " + String(lbl.dropFirst("IPSW · ".count)) }
            return "Image #\(record.id) · \(lbl)"
        }
        return "Image #\(record.id)"
    }
}
