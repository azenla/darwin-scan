import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DarwinScanCore

@main
struct DarwinScanApp: App {
    /// Cache of opened sessions, keyed by bundle URL. The `WindowGroup`
    /// presents one window per URL value SwiftUI hands us; this map keeps
    /// the live `ScanSession` instances around so reopening the same URL
    /// reuses its already-attached database instead of opening a second
    /// one.
    @State private var sessions: SessionRegistry = SessionRegistry()

    var body: some Scene {
        // Welcome window — the only window visible at launch. Acts as a
        // launcher for New / Open and gates everything else on first
        // picking a destination bundle.
        Window("DarwinScan", id: "welcome") {
            WelcomeWindowView(sessions: sessions)
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewScanCommandButton(sessions: sessions)
                OpenScanCommandButton(sessions: sessions)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { sessions.checkpointAll() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }

        // Document windows. One per bundle URL the user opens. SwiftUI
        // deduplicates by value, so `openWindow(value: url)` for an
        // already-open bundle just raises its existing window.
        WindowGroup("Scan", id: "scan", for: URL.self) { $url in
            if let url, let session = sessions.session(for: url) {
                ContentView(session: session)
                    .environment(sessions)
                    .frame(minWidth: 900, minHeight: 600)
                    .navigationTitle(session.displayName)
                    .onAppear { sessions.touchRecent(url: url) }
                    .onDisappear { sessions.close(url: url) }
            } else if let url {
                FailedToOpenView(url: url, error: sessions.lastError(for: url)) {
                    sessions.close(url: url)
                }
            } else {
                Text("No bundle selected").foregroundStyle(.secondary)
            }
        }
        .handlesExternalEvents(matching: ["*"])
    }
}

/// Menu-bar versions of the welcome buttons. SwiftUI's `openWindow`
/// environment action is only available inside a `View` body — wrapping
/// each command in its own view lets us reuse the registry while still
/// being able to open windows from a menu click.
private struct NewScanCommandButton: View {
    @Bindable var sessions: SessionRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Scan…") {
            if let url = sessions.beginNewScan() {
                openWindow(value: url)
            }
        }
        .keyboardShortcut("n", modifiers: [.command])
    }
}

private struct OpenScanCommandButton: View {
    @Bindable var sessions: SessionRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Scan…") {
            if let url = sessions.beginOpenScan() {
                openWindow(value: url)
            }
        }
        .keyboardShortcut("o", modifiers: [.command])
    }
}

/// Tracks the currently-open `ScanSession` instances and centralises the
/// New / Open / Save flows so menu commands and the welcome screen share
/// one implementation.
@Observable
@MainActor
final class SessionRegistry {
    private(set) var openSessions: [URL: ScanSession] = [:]
    private var openErrors: [URL: Error] = [:]

    /// Look up (or lazily open) the session for a bundle URL. Returns nil
    /// if the bundle can't be opened — the error is stashed under
    /// `lastError(for:)` so the failing window can surface it.
    func session(for url: URL) -> ScanSession? {
        if let existing = openSessions[url] { return existing }
        do {
            let session = try ScanSession.open(at: url)
            openSessions[url] = session
            openErrors.removeValue(forKey: url)
            return session
        } catch {
            openErrors[url] = error
            return nil
        }
    }

    func lastError(for url: URL) -> Error? { openErrors[url] }

    func close(url: URL) {
        if let session = openSessions[url] {
            session.checkpoint()
        }
        openSessions.removeValue(forKey: url)
    }

    func checkpointAll() {
        for session in openSessions.values {
            session.checkpoint()
        }
    }

    func touchRecent(url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NotificationCenter.default.post(
            name: NSDocumentController.didChangeRecentDocumentURLsNotification,
            object: nil
        )
    }

    /// Run the new-scan save panel. On success, create the empty bundle and
    /// pre-register the session so the caller's `openWindow(value:)` finds
    /// it on first lookup. Returns the chosen URL or nil if the user
    /// cancelled or creation failed.
    func beginNewScan() -> URL? {
        guard let url = runSavePanel() else { return nil }
        do {
            let session = try ScanSession.createNew(at: url)
            openSessions[url] = session
            openErrors.removeValue(forKey: url)
            touchRecent(url: url)
            return url
        } catch {
            presentError(error, fallbackTitle: "Couldn't create scan")
            return nil
        }
    }

    /// Run the open-scan picker. On success, eagerly open the session and
    /// return its URL. Returns nil on cancel or open failure.
    func beginOpenScan() -> URL? {
        guard let url = runOpenPanel() else { return nil }
        do {
            let session = try ScanSession.open(at: url)
            openSessions[url] = session
            openErrors.removeValue(forKey: url)
            touchRecent(url: url)
            return url
        } catch {
            presentError(error, fallbackTitle: "Couldn't open scan")
            return nil
        }
    }

    private func runSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Scan"
        panel.message = "Choose where to save the new scan bundle."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Scan.darwinscan"
        panel.allowedContentTypes = [.darwinScan]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "darwinscan" {
            return url.appendingPathExtension("darwinscan")
        }
        return url
    }

    private func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Scan"
        panel.allowedContentTypes = [.darwinScan]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func presentError(_ error: Error, fallbackTitle: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = fallbackTitle
        alert.informativeText = (error as CustomStringConvertible).description
        alert.runModal()
    }
}

/// Shown for windows that SwiftUI restored at launch but whose underlying
/// bundle can't be opened (deleted, moved, or corrupt).
struct FailedToOpenView: View {
    let url: URL
    let error: Error?
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Can't open \(url.lastPathComponent)")
                .font(.title3)
                .bold()
            if let error {
                Text((error as CustomStringConvertible).description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Button("Close", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
