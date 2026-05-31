import SwiftUI
import AppKit
import DarwinScanCore

struct ContentView: View {
    @Bindable var session: ScanSession
    @State private var sidebar: SidebarSelection? = .systemInfo
    @State private var itemSelection: UUID? = nil
    @State private var showNewSnapshot: Bool = false
    @State private var pendingOptions: ScanOptions = ScanOptions()
    @State private var sourceChoice: NewSnapshotSheet.SourceChoice = .currentSystem
    @State private var ipswURL: URL? = nil
    @State private var controller = ScanController()
    @State private var snapshotToDelete: SnapshotRecord? = nil
    @State private var ipswPrepStatus: String? = nil  // non-nil → "preparing IPSW" overlay

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: session.store,
                selection: $sidebar,
                onActivateSnapshot: { id in session.store.setActiveSnapshot(id) },
                onDeleteSnapshot: { snap in snapshotToDelete = snap },
                onAnalyzeSnapshot: { id in
                    controller.startAnalysis(snapshotID: id, options: session.store.options, in: session.store)
                }
            )
            .frame(minWidth: 220, idealWidth: 260)
        } content: {
            ItemListView(
                store: session.store,
                selection: sidebar ?? .systemInfo,
                itemSelection: $itemSelection
            )
            .frame(minWidth: 300, idealWidth: 380)
        } detail: {
            switch session.loadingState {
            case .pendingFirstLoad, .loading:
                BundleLoadingView(label: session.displayName)
            case .failed(let msg):
                ContentUnavailableView("Couldn't load bundle", systemImage: "exclamationmark.triangle.fill", description: Text(msg))
            case .ready:
                if session.store.itemCount == 0 && !controller.isRunning {
                    WelcomeView { showNewSnapshotSheet() }
                } else {
                    DetailView(store: session.store, itemSelection: $itemSelection)
                        .frame(minWidth: 360, idealWidth: 540)
                }
            }
        }
        .task {
            await session.populateInitialView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewSnapshotSheet()
                } label: {
                    Label("New Snapshot", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(controller.isRunning)
                .help("Import from current system or an IPSW")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.startAnalysis(
                        snapshotID: session.store.activeSnapshotID,
                        options: session.store.options,
                        in: session.store
                    )
                } label: {
                    Label("Analyze", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(controller.isRunning || session.store.activeSnapshotID == nil)
                .help("Run analysis on the active snapshot")
            }
            if controller.isRunning {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        controller.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if controller.isRunning {
                ScanProgressBar(progress: controller.progress, onCancel: { controller.cancel() })
            }
        }
        .sheet(isPresented: $showNewSnapshot) {
            NewSnapshotSheet(
                options: $pendingOptions,
                sourceChoice: $sourceChoice,
                ipswURL: $ipswURL,
                onCancel: { showNewSnapshot = false },
                onStart: {
                    let opts = pendingOptions
                    showNewSnapshot = false
                    switch sourceChoice {
                    case .currentSystem:
                        // CurrentSystemSource calls SystemInfoCollector.capture()
                        // which spawns /usr/bin/csrutil — that can block for
                        // several seconds. Build the source off-main.
                        ipswPrepStatus = "Preparing source…"
                        Task.detached(priority: .userInitiated) {
                            let source = CurrentSystemSource(options: opts)
                            await MainActor.run {
                                ipswPrepStatus = nil
                                controller.startImport(source: source, options: opts, into: session.store)
                            }
                        }
                    case .ipsw:
                        guard let ipsw = ipswURL else { return }
                        ipswPrepStatus = "Preparing IPSW…"
                        Task {
                            do {
                                let source = try await IPSWSource.prepare(
                                    ipswURL: ipsw,
                                    options: opts,
                                    progress: { line in
                                        Task { @MainActor in ipswPrepStatus = line }
                                    }
                                )
                                await MainActor.run {
                                    ipswPrepStatus = nil
                                    for diag in source.diagnostics {
                                        print("[IPSW] \(diag)")
                                    }
                                    controller.startImport(source: source, options: opts, into: session.store)
                                }
                            } catch {
                                await MainActor.run {
                                    ipswPrepStatus = nil
                                    presentError(error)
                                }
                            }
                        }
                    }
                }
            )
        }
        .overlay {
            if let status = ipswPrepStatus {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(status)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Text("Setting up the source for this import. For an IPSW this includes extract + decrypt + mount and can take several minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.thickMaterial)
                    )
                }
                .transition(.opacity)
            }
        }
        .alert("Delete snapshot?", isPresented: Binding(get: { snapshotToDelete != nil }, set: { if !$0 { snapshotToDelete = nil } })) {
            Button("Cancel", role: .cancel) { snapshotToDelete = nil }
            Button("Delete", role: .destructive) {
                if let snap = snapshotToDelete { session.store.deleteSnapshot(snap.id) }
                snapshotToDelete = nil
            }
        } message: {
            if let snap = snapshotToDelete {
                Text("\(snap.label ?? "Snapshot \(snap.id)") (\(snap.sourceKind.displayName)) will be removed. Items only referenced by this snapshot are deleted.")
            }
        }
    }

    private func showNewSnapshotSheet() {
        pendingOptions = session.store.options
        sourceChoice = .currentSystem
        ipswURL = nil
        showNewSnapshot = true
    }

    @ViewBuilder
    private func BundleLoadingView(label: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Opening \(label)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Reading the active snapshot from disk.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't start import"
        alert.informativeText = (error as CustomStringConvertible).description
        alert.runModal()
    }
}
