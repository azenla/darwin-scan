import SwiftUI

/// Empty-state view shown when a fresh document is created and no scan has
/// run yet. Big "Start Scan" button.
struct WelcomeView: View {
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("DarwinScan")
                .font(.largeTitle)
                .bold()
            Text("Catalogue everything interesting in the macOS system image — executables, launch services, frameworks, ML models, icons, man pages, localizations, and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button(action: onScan) {
                Label("Run System Scan", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("User data (/Users, /Applications, /Library) is never read.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
