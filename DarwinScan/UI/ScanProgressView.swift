import SwiftUI

/// Toolbar / sheet view for an in-flight scan. Shows phase, current path,
/// running counts, and a cancel button.
struct ScanProgressBar: View {
    let progress: ScanProgress
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout)
                    .lineLimit(1)
                Text(progress.currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(progress.itemsFound) items / \(progress.filesVisited) visited")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var headline: String {
        switch progress.phase {
        case .idle:         return "Idle"
        case .enumerating:  return "Enumerating files…"
        case .inspecting:   return "Inspecting…"
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
                ForEach(options.roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Inspection") {
                Toggle("Hash every file (SHA-256)", isOn: $options.hashFiles)
                Toggle("Index man pages", isOn: $options.indexManPages)
                Toggle("Inspect localizations (.strings)", isOn: $options.inspectLocalizations)
                Toggle("Inspect ML models", isOn: $options.inspectMLModels)
                Toggle("Inspect dyld_shared_cache headers", isOn: $options.inspectDyldCache)
                Toggle("Follow symbolic links", isOn: $options.followSymlinks)
            }

            GroupBox("Strings Cache") {
                Toggle("Extract printable strings from Mach-O executables", isOn: $options.extractStrings)
                Stepper("Min length: \(options.stringsMinLength)", value: $options.stringsMinLength, in: 4...64)
                    .disabled(!options.extractStrings)
                Text("Increases scan time substantially. Strings are stored inside the .darwinscan bundle for offline search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
