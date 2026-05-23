import SwiftUI
import AppKit

/// Trailing column. Renders the appropriate detail subview based on the
/// selected item's category.
struct DetailView: View {
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        if let id = itemSelection, let item = store.items[id] {
            DetailContent(item: item, store: store, itemSelection: $itemSelection)
        } else {
            ContentUnavailableView(
                "No Item Selected",
                systemImage: "rectangle.on.rectangle",
                description: Text("Pick an item from the list to see its details.")
            )
        }
    }
}

private struct DetailContent: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let exec = item.executable {
                    ExecutableDetailView(item: item, info: exec, store: store)
                }
                if let app = item.application {
                    AppBundleDetailView(item: item, info: app, store: store)
                }
                if let ls = item.launchService {
                    LaunchServiceDetailView(info: ls)
                }
                if let fw = item.framework {
                    FrameworkDetailView(info: fw)
                }
                if let model = item.mlModel {
                    MLModelDetailView(info: model)
                }
                if let icon = item.icon {
                    IconDetailView(info: icon, store: store)
                }
                if let man = item.manPage {
                    ManPageDetailView(item: item, info: man)
                }
                if let loc = item.localization {
                    LocalizationDetailView(info: loc)
                }
                if let cache = item.dyldCache {
                    DyldCacheDetailView(info: cache)
                }
                if let script = item.script {
                    ScriptDetailView(item: item, info: script)
                }

                if !item.relationships.isEmpty {
                    RelationshipsView(item: item, store: store, itemSelection: $itemSelection)
                }
                IncomingReferencesView(item: item, store: store, itemSelection: $itemSelection)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(item.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.category.systemImageName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(item.name)
                    .font(.title2)
                    .bold()
            }
            Text(item.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Label(ByteFormat.string(item.size), systemImage: "scalemass")
                if let mtime = item.modifiedAt {
                    Label(ByteFormat.compactDate(mtime), systemImage: "clock")
                }
                if let sha = item.sha256 {
                    Label(sha.prefix(12) + "…", systemImage: "number")
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !item.tags.isEmpty {
                TagChips(tags: item.tags)
            }
            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "eye")
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Per-category detail subviews

private struct ExecutableDetailView: View {
    let item: ScanItem
    let info: ExecutableInfo
    @Bindable var store: ScanStore

    var body: some View {
        GroupBox("Executable") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Kind", value: info.kind.rawValue.capitalized)
                LabeledContent("Architectures", value: info.architectures.joined(separator: ", "))
                if info.isFatBinary { LabeledContent("Fat Binary", value: "Yes") }
                if let platform = info.platform {
                    LabeledContent("Platform", value: platform)
                }
                if let minOS = info.minOS {
                    LabeledContent("Min OS", value: minOS)
                }
                if let sdk = info.sdkVersion {
                    LabeledContent("SDK", value: sdk)
                }
                if let usage = info.usageLine {
                    LabeledContent("Usage") {
                        Text(usage)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                }
                LabeledContent("Apple-shipped", value: info.isApple ? "Yes" : "No")
                if info.isCrossPlatformTool {
                    LabeledContent("Cross-platform", value: "Yes")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !info.linkedLibraries.isEmpty {
            GroupBox("Linked Libraries (\(info.linkedLibraries.count))") {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(info.linkedLibraries, id: \.self) { lib in
                            Text(lib)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        if !info.rpaths.isEmpty {
            GroupBox("RPATHs") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(info.rpaths, id: \.self) { rp in
                        Text(rp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let ref = info.stringsBlobRef, let data = store.blob(forRef: ref),
           let text = String(data: data, encoding: .utf8) {
            GroupBox("Strings (\(ByteFormat.string(Int64(data.count))))") {
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
        }
    }
}

private struct AppBundleDetailView: View {
    let item: ScanItem
    let info: AppBundleInfo
    @Bindable var store: ScanStore

    var body: some View {
        GroupBox("Application") {
            HStack(alignment: .top, spacing: 12) {
                if let ref = info.iconRef, let data = store.blob(forRef: ref), let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let id = info.bundleIdentifier {
                        LabeledContent("Bundle ID", value: id)
                    }
                    if let v = info.shortVersionString {
                        LabeledContent("Version", value: v + (info.bundleVersion.map { " (\($0))" } ?? ""))
                    }
                    if let exec = info.executableName {
                        LabeledContent("Executable", value: exec)
                    }
                    if let category = info.category {
                        LabeledContent("Category", value: category)
                    }
                    if info.isHidden {
                        LabeledContent("Visibility", value: "Hidden (LSUIElement)")
                    }
                    if info.isAgentApp {
                        LabeledContent("Mode", value: "Background-only")
                    }
                    if !info.urlSchemes.isEmpty {
                        LabeledContent("URL Schemes", value: info.urlSchemes.joined(separator: ", "))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LaunchServiceDetailView: View {
    let info: LaunchServiceInfo
    var body: some View {
        GroupBox(info.kind == .daemon ? "Launch Daemon" : "Launch Agent") {
            VStack(alignment: .leading, spacing: 4) {
                if let label = info.label {
                    LabeledContent("Label", value: label)
                }
                if let program = info.program {
                    LabeledContent("Program", value: program)
                }
                if !info.programArguments.isEmpty {
                    LabeledContent("Arguments", value: info.programArguments.joined(separator: " "))
                }
                LabeledContent("RunAtLoad", value: info.runAtLoad ? "Yes" : "No")
                LabeledContent("KeepAlive", value: info.keepAlive ? "Yes" : "No")
                if let interval = info.startInterval {
                    LabeledContent("StartInterval", value: "\(interval)s")
                }
                if !info.machServices.isEmpty {
                    LabeledContent("MachServices", value: info.machServices.joined(separator: ", "))
                }
                if !info.watchPaths.isEmpty {
                    LabeledContent("WatchPaths", value: info.watchPaths.joined(separator: "\n"))
                }
                if let user = info.userName {
                    LabeledContent("UserName", value: user)
                }
                if info.disabled {
                    LabeledContent("Status", value: "Disabled")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FrameworkDetailView: View {
    let info: FrameworkInfo
    var body: some View {
        GroupBox(info.isPrivate ? "Private Framework" : "Framework / Library") {
            VStack(alignment: .leading, spacing: 4) {
                if let id = info.bundleIdentifier {
                    LabeledContent("Bundle ID", value: id)
                }
                if let v = info.shortVersionString {
                    LabeledContent("Version", value: v)
                }
                if let curr = info.currentVersion {
                    LabeledContent("Current Version", value: curr)
                }
                if let exec = info.executableName {
                    LabeledContent("Executable", value: exec)
                }
                if info.headerCount > 0 {
                    LabeledContent("Public Headers", value: "\(info.headerCount)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MLModelDetailView: View {
    let info: MLModelInfo
    var body: some View {
        GroupBox("Machine Learning Model") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Container", value: info.container.rawValue)
                if let t = info.modelType { LabeledContent("Type", value: t) }
                if let desc = info.modelDescription { LabeledContent("Description", value: desc) }
                if let author = info.author { LabeledContent("Author", value: author) }
                if let lic = info.license { LabeledContent("License", value: lic) }
                if let labels = info.classLabelsCount { LabeledContent("Class Labels", value: "\(labels)") }
                if !info.inputs.isEmpty { LabeledContent("Inputs", value: info.inputs.joined(separator: ", ")) }
                if !info.outputs.isEmpty { LabeledContent("Outputs", value: info.outputs.joined(separator: ", ")) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct IconDetailView: View {
    let info: IconInfo
    @Bindable var store: ScanStore
    var body: some View {
        GroupBox("Icon") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Kind", value: info.kind.rawValue)
                if !info.representations.isEmpty {
                    LabeledContent("Representations", value: info.representations.joined(separator: ", "))
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ManPageDetailView: View {
    let item: ScanItem
    let info: ManPageInfo
    @State private var renderedText: String? = nil

    var body: some View {
        GroupBox("Man Page") {
            VStack(alignment: .leading, spacing: 4) {
                if let s = info.section { LabeledContent("Section", value: s) }
                if let t = info.title { LabeledContent("Title", value: t) }
                if let d = info.description { LabeledContent("Synopsis", value: d) }
                if info.compressed { LabeledContent("Compressed", value: "Yes (gzip)") }
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
                    Button("Render Source") { renderText() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func renderText() {
        // Re-parse from the source URL — we don't keep the rendered source in
        // the store yet to avoid bloating bundles. Cheap re-read on demand.
        let url = URL(fileURLWithPath: item.path)
        if let (_, text) = ManPageInspector.inspect(url: url) {
            renderedText = text
        }
    }
}

private struct LocalizationDetailView: View {
    let info: LocalizationInfo
    var body: some View {
        GroupBox("Localization") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Kind", value: info.kind.rawValue)
                if let lang = info.language { LabeledContent("Language", value: lang) }
                if let count = info.keyCount { LabeledContent("Keys", value: "\(count)") }
                if let id = info.owningBundleId { LabeledContent("Owning Bundle", value: id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DyldCacheDetailView: View {
    let info: DyldCacheInfo
    var body: some View {
        GroupBox("DYLD Shared Cache") {
            VStack(alignment: .leading, spacing: 4) {
                if let arch = info.architecture { LabeledContent("Architecture", value: arch) }
                if let v = info.formatVersion { LabeledContent("Format Magic", value: v) }
                if let n = info.imageCount { LabeledContent("Images", value: "\(n)") }
                if let m = info.mappingCount { LabeledContent("Mappings", value: "\(m)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ScriptDetailView: View {
    let item: ScanItem
    let info: ScriptInfo
    var body: some View {
        GroupBox("Script") {
            VStack(alignment: .leading, spacing: 4) {
                if let interp = info.interpreter { LabeledContent("Interpreter", value: interp) }
                if let lang = info.language { LabeledContent("Language", value: lang) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Graph views (outgoing + incoming edges)

/// Outgoing relationships defined on the item itself: dylib links, the
/// program a launchd plist runs, the bundle that owns this file, etc. Each
/// row is clickable if the target path also appears in this scan.
private struct RelationshipsView: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        let grouped = Dictionary(grouping: item.relationships, by: { $0.kind })
        ForEach(Relationship.Kind.allRenderable, id: \.self) { kind in
            if let rels = grouped[kind], !rels.isEmpty {
                GroupBox(label: Label(title(for: kind), systemImage: systemImage(for: kind))) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rels.enumerated()), id: \.offset) { (_, rel) in
                            RelationshipRow(rel: rel, store: store, itemSelection: $itemSelection)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func title(for kind: Relationship.Kind) -> String {
        switch kind {
        case .linksDylib:       return "Links Libraries"
        case .ownedByBundle:    return "Inside Bundle"
        case .launchesProgram:  return "Launches Program"
        case .sameBundle:       return "Bundle Siblings"
        }
    }

    private func systemImage(for kind: Relationship.Kind) -> String {
        switch kind {
        case .linksDylib:       return "link"
        case .ownedByBundle:    return "shippingbox"
        case .launchesProgram:  return "play.fill"
        case .sameBundle:       return "square.stack.3d.up"
        }
    }
}

private extension Relationship.Kind {
    /// Order we surface kinds in the UI. Excludes any future internal kinds.
    static var allRenderable: [Relationship.Kind] {
        [.ownedByBundle, .launchesProgram, .linksDylib, .sameBundle]
    }
}

/// Inverse-edge index: who else in this scan points *at* the current item.
/// We compute on demand by scanning all items' relationship lists. Cheap for
/// /System-sized scans (tens of thousands of items, a few edges each).
private struct IncomingReferencesView: View {
    let item: ScanItem
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        let incoming = computeIncoming()
        if incoming.isEmpty {
            EmptyView()
        } else {
            GroupBox(label: Label("Referenced By (\(incoming.count))", systemImage: "arrow.turn.up.left")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(incoming.prefix(64), id: \.id) { ref in
                        Button {
                            itemSelection = ref.id
                        } label: {
                            HStack {
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
                    if incoming.count > 64 {
                        Text("…\(incoming.count - 64) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func computeIncoming() -> [ScanItem] {
        let myPath = item.path
        var results: [ScanItem] = []
        for other in store.items.values {
            if other.id == item.id { continue }
            for rel in other.relationships {
                if rel.targetPath == myPath {
                    results.append(other)
                    break
                }
            }
        }
        return results.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

private struct RelationshipRow: View {
    let rel: Relationship
    @Bindable var store: ScanStore
    @Binding var itemSelection: UUID?

    var body: some View {
        let target = store.item(atPath: rel.targetPath)
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
                // Target not in this scan — show the raw path (e.g. an
                // @rpath-relative dylib or an OS-level dylib not enumerated).
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
    }
}

// MARK: - System info overview

struct SystemInfoView: View {
    @Bindable var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let info = store.systemInfo {
                GroupBox("Host") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let p = info.productName, let v = info.productVersion {
                            LabeledContent("OS", value: "\(p) \(v)")
                        }
                        if let b = info.productBuildVersion {
                            LabeledContent("Build", value: b)
                        }
                        if let h = info.hardwareModel {
                            LabeledContent("Model", value: h)
                        }
                        if let cpu = info.cpuBrand {
                            LabeledContent("CPU", value: cpu)
                        }
                        if !info.architectures.isEmpty {
                            LabeledContent("Architectures", value: info.architectures.joined(separator: ", "))
                        }
                        if let host = info.hostName {
                            LabeledContent("Hostname", value: host)
                        }
                        if let sip = info.sipStatus {
                            LabeledContent("SIP", value: sip)
                        }
                        LabeledContent("Captured", value: ByteFormat.compactDate(info.capturedAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let kv = info.kernelVersion {
                    GroupBox("Kernel") {
                        Text(kv)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let boot = info.bootArgs, !boot.isEmpty {
                    GroupBox("Boot Args") {
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
                    description: Text("Run a scan to capture host information.")
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
