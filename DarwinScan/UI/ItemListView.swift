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
    /// when `ListInputs` changes — *not* on row clicks. The store never
    /// keeps all headers in memory; per-row hydration goes via
    /// `store.itemHeader(id:)` which is SQL-backed + LRU-cached, so the
    /// only persistent state for the list is this `[UUID]`.
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
                    // NSTableView-backed: only the visible rows are
                    // realised regardless of `filteredItemIDs.count`. The
                    // SwiftUI `List(...)` initialiser allocates an
                    // AttributeGraph node per id and exhausts the graph's
                    // data space well before 470k items.
                    ItemTableView(
                        ids: filteredItemIDs,
                        selection: $itemSelection,
                        store: store
                    )
                }
                .searchable(text: $rawSearchText, prompt: searchPrompt)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .task(id: ListInputs(searchText: rawSearchText,
                             selection: selection,
                             itemCount: store.itemCount)) {
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

    /// Stream headers out of SQLite (already ORDER BY name COLLATE NOCASE
    /// via an index), apply the search filter in memory, and keep only
    /// the matching IDs. No full-snapshot header set is ever materialised
    /// — peak memory is bounded by the result size plus one in-flight
    /// header at a time.
    ///
    /// Memory profile, /System scan (~470k items):
    /// - filteredItemIDs: ≤ N_matches × 16 B (≤ 7.5 MB for All Items).
    /// - in-flight header during walk: ~250 B.
    ///
    /// Previously the equivalent path snapshotted every header into a
    /// `[(UUID, String, String)]` tuple array and sorted that on a
    /// detached task — ~140 MB for a /System scan, before the heap
    /// counted the in-memory items dict itself.
    private func recompute() async {
        if case .systemInfo = selection {
            filteredItemIDs = []
            displayedFilters = []
            return
        }
        let query = SearchQuery.parse(rawSearchText)
        let scopeFilter = scope
        let allowedFTS: Set<UUID>? = query.resolveFTSItemIDs(against: store)

        let isCancelled = { Task.isCancelled }
        let store = self.store
        // SQL ORDER BY name keeps us out of the sort step entirely for
        // the common case. The detached task isolates the streaming +
        // filter from MainActor; only the final `[UUID]` crosses back.
        let result: [UUID] = await Task.detached(priority: .userInitiated) {
            var ids: [UUID] = []
            ids.reserveCapacity(scopeFilter.map { store.categoryCounts[$0] ?? 0 } ?? min(store.itemCount, 65_536))
            store.forEachHeader(category: scopeFilter) { header in
                if isCancelled() { return false }
                if let allowed = allowedFTS, !allowed.contains(header.id) { return true }
                if !query.isEmpty && !query.matches(header) { return true }
                ids.append(header.id)
                return true
            }
            return ids
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
                Text(PathCompactor.compact(header.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(header.path)
            }
            Spacer()
            if !header.tags.isEmpty {
                TagChips(tags: Array(header.tags.prefix(3)))
            }
        }
    }
}

/// Render long paths compactly for list rows.
///
/// Rule: keep the **last two** path components verbatim, shorten earlier
/// components to their capital initials (or first character when the
/// component has no capitals). The full path remains in the detail view
/// and as the row's tooltip.
///
/// Examples:
///   /System/Library/PrivateFrameworks/Foo.framework/Versions/A/Foo
///     -> /S/L/PF/F.framework/V/A/Foo
///   /usr/share/man/man1/ls.1
///     -> /u/s/m/man1/ls.1
///   /bin/ls
///     -> /bin/ls          (≤2 trailing components, unchanged)
///
/// Virtual dyld-cache paths use `#` as the separator between the cache
/// file and the image path; we treat the part after `#` as its own path
/// for compaction so an arm64e cache full of dylibs reads as
/// `/S/.../dyld_shared_cache_arm64e # /u/lib/libSystem.B.dylib`.
enum PathCompactor {
    static func compact(_ path: String) -> String {
        if let hashRange = path.range(of: "#") {
            let cache = String(path[..<hashRange.lowerBound])
            let image = String(path[hashRange.upperBound...])
            return "\(compactSegments(cache)) # \(compactSegments(image))"
        }
        return compactSegments(path)
    }

    private static func compactSegments(_ path: String) -> String {
        let leadingSlash = path.hasPrefix("/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 2 else { return path }
        let keepFromIndex = parts.count - 2
        var out: [String] = []
        out.reserveCapacity(parts.count)
        for (idx, part) in parts.enumerated() {
            out.append(idx < keepFromIndex ? initials(of: part) : part)
        }
        return (leadingSlash ? "/" : "") + out.joined(separator: "/")
    }

    private static func initials(of component: String) -> String {
        // Strip extension before initialing (e.g. "Foo.framework" -> "Foo");
        // re-attach the extension so the type cue ("F.framework") survives.
        let nsComponent = component as NSString
        let stem = nsComponent.deletingPathExtension
        let ext = nsComponent.pathExtension
        let stemInitials = initialsForStem(stem.isEmpty ? component : stem)
        if !ext.isEmpty, !stem.isEmpty {
            return "\(stemInitials).\(ext)"
        }
        return stemInitials
    }

    private static func initialsForStem(_ stem: String) -> String {
        let capitals = stem.filter { $0.isUppercase }
        if capitals.count >= 2 { return String(capitals) }
        return stem.first.map(String.init) ?? stem
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
                    osCard(info: info, sourceKind: record.sourceKind)
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
        // Title: "IPSW · UniversalMac_…" for IPSW snapshots, else "Image #N".
        // The friendly label produced by the source provider lives on
        // `record.label`; fall back to a generic "Image #N" so the column
        // never reads "Snapshot #1" for a real IPSW.
        let title: String = record.label ?? "Image #\(record.id)"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.15))
                    Image(systemName: record.sourceKind.systemImageName)
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2).bold().lineLimit(2)
                    HStack(spacing: 6) {
                        Text(record.sourceKind.displayName)
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.tint.opacity(0.12)))
                        Text(record.startedAt, format: .dateTime)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if record.importCompletedAt == nil {
                        Text("In progress").font(.caption).foregroundStyle(.orange)
                    } else if let completed = record.importCompletedAt {
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

    @ViewBuilder
    private func osCard(info: SystemInfo, sourceKind: SnapshotSourceKind) -> some View {
        switch sourceKind {
        case .currentSystem:
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
        case .ipsw:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(.tint)
                    Text("Build Info").font(.headline)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let v = info.productVersion {
                        LabeledContent("macOS", value: v)
                    }
                    if let b = info.productBuildVersion { LabeledContent("Build", value: b) }
                    if let train = info.buildTrain { LabeledContent("Train", value: train) }
                    if !info.architectures.isEmpty {
                        LabeledContent("Arch", value: info.architectures.joined(separator: ", "))
                    }
                }
                .font(.callout)
                if let devices = info.supportedProductTypes, !devices.isEmpty {
                    Divider().padding(.vertical, 2)
                    SupportedDevicesView(devices: devices)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            )
        }
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

/// Compact "Supported Devices" list with a show-all toggle so the IPSW
/// build-info card doesn't blow up vertically for a Universal Mac release
/// (those list 50+ identifiers).
private struct SupportedDevicesView: View {
    let devices: [String]
    @State private var expanded: Bool = false

    private var visibleCount: Int { expanded ? devices.count : min(devices.count, 6) }
    private var visible: [String] { Array(devices.prefix(visibleCount)) }
    private var hiddenCount: Int { max(0, devices.count - visibleCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "macbook.and.iphone").foregroundStyle(.secondary).imageScale(.small)
                Text("Supported Devices").font(.callout).bold()
                Spacer()
                Text("\(devices.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6, runSpacing: 4) {
                ForEach(visible, id: \.self) { device in
                    Text(device)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                if hiddenCount > 0 {
                    Button {
                        expanded = true
                    } label: {
                        Text("+\(hiddenCount) more")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                } else if expanded && devices.count > 6 {
                    Button {
                        expanded = false
                    } label: {
                        Text("show fewer")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// Minimal flow layout (chips wrap to the next row). Used by
/// `SupportedDevicesView` so the model-identifier chips pack densely.
private struct FlowLayout: Layout {
    let spacing: CGFloat
    let runSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
