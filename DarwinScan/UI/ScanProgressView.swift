import SwiftUI
import UniformTypeIdentifiers
import DarwinScanCore

/// Bottom toolbar shown while a scan is running.
///
/// Layout: a stable counter row up top (phase, items, visited, workers,
/// cancel) plus a collapsible "queue" panel below showing one row per
/// currently-inspecting worker. The queue is the live view of what's being
/// worked on — paths get added when a task is enqueued and removed when it
/// completes, so the list grows and shrinks but doesn't flicker between
/// individual paths the way a "currentPath" string would.
struct ScanProgressBar: View {
    let progress: ScanProgress
    var onCancel: () -> Void = {}
    @State private var showQueue: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            counterRow
            if showQueue && !progress.inFlightPaths.isEmpty {
                Divider()
                queuePanel
            }
        }
        .background(.bar)
    }

    private var counterRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.callout)
                    .lineLimit(1)
                if progress.workerCount > 0 {
                    Text("\(progress.activeWorkers) of \(progress.workerCount) workers active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statsView
            Button {
                showQueue.toggle()
            } label: {
                Image(systemName: showQueue ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(showQueue ? "Hide queue" : "Show queue")
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statsView: some View {
        HStack(spacing: 14) {
            switch progress.phase {
            case .analyzing, .inspecting:
                // "analyzed of total" — how far through the snapshot we are.
                statColumn(label: "analyzed", value: progress.filesInspected)
                if progress.itemsFound > 0 {
                    statColumn(label: "total", value: progress.itemsFound)
                }
            case .importing, .enumerating:
                // "imported" = items captured; "scanned" = files the walker
                // has reached. ("visited"/"inspected" were jargon — and
                // "inspected" was meaningless during import, which doesn't
                // run inspectors.)
                statColumn(label: "imported", value: progress.itemsFound)
                statColumn(label: "scanned", value: progress.filesVisited)
            default:
                statColumn(label: "items", value: progress.itemsFound)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func statColumn(label: String, value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(value)")
                .foregroundStyle(.primary)
            Text(label)
                .foregroundStyle(.tertiary)
                .font(.caption2)
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(progress.inFlightPaths.enumerated()), id: \.offset) { (idx, path) in
                HStack(spacing: 6) {
                    workerIndexBadge(idx: idx)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Tiny circular badge showing which worker slot a path belongs to. The
    /// index is by enqueue order, not stable across the whole scan, but it
    /// gives a visual cue when the same row updates.
    private func workerIndexBadge(idx: Int) -> some View {
        Text("\(idx + 1)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(.tint.opacity(0.85)))
    }

    private var headline: String {
        switch progress.phase {
        case .idle:         return "Idle"
        case .enumerating:  return "Enumerating files…"
        case .importing:    return "Importing files…"
        case .analyzing:    return "Analyzing items…"
        case .inspecting:   return "Inspecting in parallel…"
        case .writing:      return "Writing…"
        case .done:         return "Done"
        case .failed:       return progress.lastError ?? "Failed"
        }
    }
}

/// Sheet for adding a snapshot — pick a source (current system or IPSW) and
/// review options. Replaces the old "scan options" sheet which couldn't tell
/// the user where the bytes were coming from.
struct NewSnapshotSheet: View {
    @Binding var options: ScanOptions
    @Binding var sourceChoice: SourceChoice
    @Binding var ipswURL: URL?
    var onCancel: () -> Void
    var onStart: () -> Void

    enum SourceChoice: String, CaseIterable, Identifiable {
        case currentSystem
        case ipsw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .currentSystem: return "Current System"
            case .ipsw:          return "IPSW Image"
            }
        }
        var symbol: String {
            switch self {
            case .currentSystem: return "desktopcomputer"
            case .ipsw:          return "shippingbox"
            }
        }
        var blurb: String {
            switch self {
            case .currentSystem:
                return "Walk this Mac's /System, /bin, /sbin, /usr and capture file bytes into the bundle."
            case .ipsw:
                return "Mount an IPSW image (Apple Silicon Mac or device) and import its system payload. Each IPSW becomes a snapshot — chain two to diff across an OS update."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Snapshot")
                .font(.title2).bold()

            // Source picker — pretty cards
            HStack(spacing: 12) {
                ForEach(SourceChoice.allCases) { choice in
                    SourceCard(
                        choice: choice,
                        selected: sourceChoice == choice,
                        onTap: { sourceChoice = choice }
                    )
                }
            }

            if sourceChoice == .ipsw {
                GroupBox("IPSW File") {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.tint)
                        if let url = ipswURL {
                            Text(url.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No IPSW selected")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose…", action: pickIPSW)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Import captures a copy of every file's bytes into the bundle, so analysis can run — and re-run — without the original source. Analysis is a separate step you can start or re-run from the toolbar; you only pay the capture cost once.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Start Import", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourceChoice == .ipsw && ipswURL == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 600)
    }

    private func pickIPSW() {
        let panel = NSOpenPanel()
        panel.title = "Choose IPSW"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let ipsw = UTType(filenameExtension: "ipsw") {
            panel.allowedContentTypes = [ipsw]
        }
        if panel.runModal() == .OK, let url = panel.url {
            ipswURL = url
        }
    }
}

private struct SourceCard: View {
    let choice: NewSnapshotSheet.SourceChoice
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: choice.symbol)
                        .font(.title)
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white)
                    }
                }
                Text(choice.label)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(choice.blurb)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            // Fixed height — without this the IPSW card (longer blurb)
            // grows taller than the Current System card and the two-up row
            // looks uneven. Spacer above eats any leftover space so the
            // top-aligned content stays the same regardless of card text.
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor : Color.gray.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// Compatibility shim — older call sites still expect this name.
typealias ScanOptionsSheet = NewSnapshotSheet
