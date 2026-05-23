import SwiftUI

struct ContentView: View {
    let document: ScanDocument
    @State private var sidebar: SidebarSelection? = .systemInfo
    @State private var itemSelection: UUID? = nil
    @State private var showOptions: Bool = false
    @State private var pendingOptions: ScanOptions = ScanOptions()
    @State private var controller = ScanController()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: document.store, selection: $sidebar)
                .frame(minWidth: 220, idealWidth: 240)
        } content: {
            ItemListView(
                store: document.store,
                selection: sidebar ?? .systemInfo,
                itemSelection: $itemSelection
            )
            .frame(minWidth: 300, idealWidth: 380)
        } detail: {
            if document.store.items.isEmpty && !controller.isRunning {
                WelcomeView { showScanOptions() }
            } else {
                DetailView(store: document.store, itemSelection: $itemSelection)
                    .frame(minWidth: 360, idealWidth: 540)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showScanOptions()
                } label: {
                    Label(controller.isRunning ? "Scanning…" : "Scan", systemImage: "magnifyingglass")
                }
                .disabled(controller.isRunning)
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
        .sheet(isPresented: $showOptions) {
            ScanOptionsSheet(
                options: $pendingOptions,
                onCancel: { showOptions = false },
                onStart: {
                    let opts = pendingOptions
                    showOptions = false
                    controller.startScan(options: opts, ingestInto: document.store)
                }
            )
        }
    }

    private func showScanOptions() {
        pendingOptions = document.store.options
        showOptions = true
    }
}
