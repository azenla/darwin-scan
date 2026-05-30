import SwiftUI
import AppKit
import DarwinScanCore

/// Per-document empty state shown in the detail column when a session has
/// been opened but no scan has run yet. The big "Run System Scan" button
/// is the obvious-call-to-action — there's nothing else useful to render
/// in the detail column when `store.items.isEmpty`.
struct WelcomeView: View {
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Add the first snapshot")
                .font(.title2).bold()
            Text("Import the current system or an IPSW. The bundle can hold many snapshots — chain two IPSWs to diff a macOS upgrade, or rescan over time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button(action: onScan) {
                Label("Add Snapshot…", systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Import captures file bytes. Analysis is a separate phase you can re-run anytime.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The launcher window. Shown on app launch (and any time the user closes
/// every scan window). Owns the New / Open / Recent flows — the previous
/// `DocumentGroup`-driven `Untitled.darwinscan` autocreate is gone: a scan
/// can only start once the user has chosen a destination on disk.
struct WelcomeWindowView: View {
    @Bindable var sessions: SessionRegistry
    @Environment(\.openWindow) private var openWindow
    @State private var recentURLs: [URL] = []

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("DarwinScan")
                .font(.largeTitle)
                .bold()
            Text("Catalogue everything interesting in the macOS system image — executables, launch services, frameworks, ML models, icons, man pages, localizations, and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button {
                    if let url = sessions.beginNewScan() {
                        openWindow(value: url)
                    }
                } label: {
                    Label("New Scan…", systemImage: "plus.circle.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: [.command])

                Button {
                    if let url = sessions.beginOpenScan() {
                        openWindow(value: url)
                    }
                } label: {
                    Label("Open Scan…", systemImage: "folder.fill")
                        .frame(minWidth: 130)
                }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command])
            }
            .padding(.top, 4)

            if !recentURLs.isEmpty {
                Divider().padding(.horizontal, 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recentURLs, id: \.self) { url in
                        Button {
                            sessions.touchRecent(url: url)
                            openWindow(value: url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }

            Spacer(minLength: 0)
            Text("User data (/Users, /Applications, /Library) is never read.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { recentURLs = NSDocumentController.shared.recentDocumentURLs }
        .onReceive(NotificationCenter.default.publisher(for: NSDocumentController.didChangeRecentDocumentURLsNotification)) { _ in
            recentURLs = NSDocumentController.shared.recentDocumentURLs
        }
        .onOpenURL { url in
            sessions.touchRecent(url: url)
            openWindow(value: url)
        }
    }
}

extension NSDocumentController {
    static let didChangeRecentDocumentURLsNotification = Notification.Name("DarwinScanRecentChanged")
}
