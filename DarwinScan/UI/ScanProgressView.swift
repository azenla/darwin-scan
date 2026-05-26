import SwiftUI
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
                    Text("\(progress.inFlightPaths.count) of \(progress.workerCount) workers active")
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
            statColumn(label: "items", value: progress.itemsFound)
            statColumn(label: "visited", value: progress.filesVisited)
            statColumn(label: "inspected", value: progress.filesInspected)
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
        case .inspecting:   return "Inspecting in parallel…"
        case .writing:      return "Writing…"
        case .done:         return "Done"
        case .failed:       return progress.lastError ?? "Failed"
        }
    }
}

/// Sheet shown before a scan starts so the user can review options.
struct ScanOptionsSheet: View {
    @Binding var options: ScanOptions
    var onCancel: () -> Void
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Scan")
                .font(.title2)
                .bold()
            Text("Restricted to system-image paths. User data (/Users, /Applications, /Library, /Volumes) is never read.")
                .foregroundStyle(.secondary)
                .font(.callout)

            GroupBox("Roots") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options.roots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder")
                            Text(root)
                                .font(.system(.callout, design: .monospaced))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Inspection") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hash every file (SHA-256)", isOn: $options.hashFiles)
                    Toggle("Index man pages", isOn: $options.indexManPages)
                    Toggle("Inspect localizations (.strings)", isOn: $options.inspectLocalizations)
                    Toggle("English localizations only", isOn: $options.englishLocalizationsOnly)
                        .disabled(!options.inspectLocalizations)
                        .padding(.leading, 18)
                    Toggle("Inspect ML models", isOn: $options.inspectMLModels)
                    Toggle("Inspect dyld_shared_cache headers", isOn: $options.inspectDyldCache)
                    Toggle("Follow symbolic links", isOn: $options.followSymlinks)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Strings Cache") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Extract printable strings from Mach-O executables", isOn: $options.extractStrings)
                    Stepper("Min length: \(options.stringsMinLength)", value: $options.stringsMinLength, in: 4...64)
                        .disabled(!options.extractStrings)
                    Text("Increases scan time substantially. Strings are stored inside the .darwinscan bundle for offline search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Start Scan", action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540)
    }
}
